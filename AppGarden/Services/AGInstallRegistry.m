/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGInstallRegistry.h"
#import "AGApp.h"

static NSString *const AGRegistryFileName = @"Installed.plist";

/* The home-relative default is built here rather than read from a user
 * default: the registry is application state, not a preference, and tests
 * point it at a temporary directory instead of overriding anything. */
static NSString *AGDefaultRegistryDirectory(void)
{
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/AppGarden"];
}

@implementation AGInstallRegistry
{
  NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *_entries;
}

- (instancetype)initWithDirectory:(NSString *)directory
{
  NSParameterAssert(directory != nil);

  self = [super init];
  if (self)
    {
      _directory = [directory copy];
      _entries = [NSMutableDictionary dictionary];

      /* Read once, here: every later query answers from memory, so a write
       * can never race a re-read and the plist is only the handover between
       * launches. */
      NSString *path = [_directory stringByAppendingPathComponent:AGRegistryFileName];
      NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
      if (plist != nil)
        {
          id key;
          for (key in plist)
            {
              id value = [plist objectForKey:key];
              if ([key isKindOfClass:[NSString class]] &&
                  [value isKindOfClass:[NSDictionary class]])
                [_entries setObject:value forKey:key];
            }
        }

      /* Creating the directory costs nothing on the first launch and lets
       * every later write be a plain atomic file write. */
      [[NSFileManager defaultManager] createDirectoryAtPath:_directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
    }
  return self;
}

- (instancetype)init
{
  return [self initWithDirectory:AGDefaultRegistryDirectory()];
}

- (NSArray<NSString *> *)installedNames
{
  @synchronized (self)
    {
      /* Sorted so anything that lists names (the Installed page, a test)
       * sees one stable order instead of the dictionary's. */
      return [[_entries allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NSDictionary<NSString *, id> *)entryForName:(NSString *)name
{
  if (name == nil)
    return nil;
  @synchronized (self)
    {
      return [_entries objectForKey:name];
    }
}

- (void)recordApp:(AGApp *)app path:(NSString *)path
{
  NSParameterAssert([app name] != nil);
  NSParameterAssert(path != nil);

  @synchronized (self)
    {
      NSDictionary *entry = @{
        @"path": path,
        @"installedAt": [NSDate date],
        @"displayName": [app displayName],
      };
      [_entries setObject:entry forKey:[app name]];
      [self save];
    }
}

- (void)removeEntryForName:(NSString *)name
{
  if (name == nil)
    return;
  @synchronized (self)
    {
      if ([_entries objectForKey:name] == nil)
        return;
      [_entries removeObjectForKey:name];
      [self save];
    }
}

- (void)reconcile
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray<NSString *> *gone = [NSMutableArray array];

  @synchronized (self)
    {
      NSString *name;
      for (name in _entries)
        {
          id pathValue = [[_entries objectForKey:name] objectForKey:@"path"];
          NSString *path = [pathValue isKindOfClass:[NSString class]] ? pathValue : nil;
          /* An entry without a usable path points at nothing, so it counts
           * as gone together with the ones whose file was deleted. */
          if (path == nil || ![fm fileExistsAtPath:path])
            [gone addObject:name];
        }
      if ([gone count] == 0)
        return;

      NSString *dropped;
      for (dropped in gone)
        [_entries removeObjectForKey:dropped];
      [self save];
    }
}

#pragma mark - Private

/* Written atomically on every change: a half-written plist would cost the
 * whole registry on the next launch, while an atomic replace either lands or
 * leaves the previous state intact. The write has no error channel in this
 * interface, and failing loudly here would abort an install that did
 * succeed, so a failed write simply leaves the in-memory copy authoritative
 * until the next change tries again. */
- (void)save
{
  NSString *path = [_directory stringByAppendingPathComponent:AGRegistryFileName];
  [_entries writeToFile:path atomically:YES];
}

@end
