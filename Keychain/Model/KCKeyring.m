/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCKeyring.h"
#import "KCCollection.h"

#include <stdio.h>
#include <string.h>
#include <errno.h>

NSString * const KCKeyringDidChangeCollectionsNotification =
  @"KCKeyringDidChangeCollectionsNotification";
NSString * const KCAddedCollectionKey = @"KCAddedCollection";
NSString * const KCRemovedCollectionKey = @"KCRemovedCollection";

static NSString * const KCKeyringExtension = @"keyring";
static NSString * const KCAliasesFile = @"Aliases.plist";

static NSError *KCIOError(NSString *path, NSString *what)
{
  NSString *message = [NSString stringWithFormat: @"Could not %@ %@: %s",
    what, path, strerror(errno)];
  return [NSError errorWithDomain: KCKeyringErrorDomain code: KCKeyringErrorIO
    userInfo: [NSDictionary dictionaryWithObject: message
                                          forKey: NSLocalizedDescriptionKey]];
}

@implementation KCKeyring
{
  NSString *_directory;
  NSMutableArray *_collections;
  NSMutableDictionary *_aliases;
}

+ (NSString *) defaultDirectory
{
  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
    NSUserDomainMask, YES);
  return [[dirs objectAtIndex: 0] stringByAppendingPathComponent: @"Keyrings"];
}

- (instancetype) initWithDirectory: (NSString *)directory
{
  if ((self = [super init]) != nil)
    {
      _directory = [directory copy];
      _collections = [NSMutableArray new];
      _aliases = [NSMutableDictionary new];
    }
  return self;
}

- (NSString *) pathForName: (NSString *)name
{
  return [_directory stringByAppendingPathComponent:
    [name stringByAppendingPathExtension: KCKeyringExtension]];
}

/* Secrets must never be world-readable, not even for the instant between
 * creating and chmod'ing a file, so the directory is private too. */
- (BOOL) ensureDirectory: (NSError **)error
{
  NSDictionary *attrs = [NSDictionary dictionaryWithObject:
    [NSNumber numberWithShort: 0700] forKey: NSFilePosixPermissions];

  if ([[NSFileManager defaultManager] createDirectoryAtPath: _directory
        withIntermediateDirectories: YES attributes: attrs error: NULL])
    return YES;
  if (error != NULL)
    *error = KCIOError(_directory, @"create");
  return NO;
}

- (BOOL) writeData: (NSData *)data toPath: (NSString *)path error: (NSError **)error
{
  NSString *tmp = [path stringByAppendingString: @".new"];
  NSDictionary *attrs = [NSDictionary dictionaryWithObject:
    [NSNumber numberWithShort: 0600] forKey: NSFilePosixPermissions];

  if (![self ensureDirectory: error])
    return NO;
  if (![[NSFileManager defaultManager] createFileAtPath: tmp contents: data
                                             attributes: attrs])
    {
      if (error != NULL)
        *error = KCIOError(tmp, @"write");
      return NO;
    }
  /* rename() is atomic: a reader sees the old or the new keyring, never
   * half of one. */
  if (rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) != 0)
    {
      if (error != NULL)
        *error = KCIOError(path, @"replace");
      unlink([tmp fileSystemRepresentation]);
      return NO;
    }
  return YES;
}

- (BOOL) load: (NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *aliasPath = [_directory stringByAppendingPathComponent: KCAliasesFile];
  NSArray *files;
  NSEnumerator *e;
  NSString *file;
  NSMutableArray *loaded = [NSMutableArray array];

  if (![fm fileExistsAtPath: _directory])
    {
      [_collections removeAllObjects];
      [_aliases removeAllObjects];
      return YES;
    }
  files = [fm contentsOfDirectoryAtPath: _directory error: NULL];
  if (files == nil)
    {
      if (error != NULL)
        *error = KCIOError(_directory, @"list");
      return NO;
    }
  e = [[files sortedArrayUsingSelector: @selector(compare:)] objectEnumerator];
  while ((file = [e nextObject]) != nil)
    {
      NSString *path;
      NSData *data;
      KCCollection *c;

      if (![[file pathExtension] isEqualToString: KCKeyringExtension])
        continue;
      path = [_directory stringByAppendingPathComponent: file];
      data = [NSData dataWithContentsOfFile: path];
      if (data == nil)
        {
          if (error != NULL)
            *error = KCIOError(path, @"read");
          return NO;
        }
      c = [KCCollection collectionWithName: [file stringByDeletingPathExtension]
                                  fileData: data error: error];
      if (c == nil)
        return NO;
      [loaded addObject: c];
    }

  if ([fm fileExistsAtPath: aliasPath])
    {
      NSDictionary *aliases = [NSDictionary dictionaryWithContentsOfFile: aliasPath];
      if (aliases == nil)
        {
          if (error != NULL)
            *error = [NSError errorWithDomain: KCKeyringErrorDomain
              code: KCKeyringErrorCorruptFile userInfo:
              [NSDictionary dictionaryWithObject:
                [NSString stringWithFormat: @"%@ is not readable.", aliasPath]
                                          forKey: NSLocalizedDescriptionKey]];
          return NO;
        }
      [_aliases setDictionary: aliases];
    }
  else
    [_aliases removeAllObjects];

  [_collections setArray: loaded];
  return YES;
}

- (NSArray *) collections
{
  return [NSArray arrayWithArray: _collections];
}

- (KCCollection *) collectionNamed: (NSString *)name
{
  NSEnumerator *e = [_collections objectEnumerator];
  KCCollection *c;

  while ((c = [e nextObject]) != nil)
    {
      if ([[c name] isEqualToString: name])
        return c;
    }
  return nil;
}

- (KCCollection *) collectionForAlias: (NSString *)alias
{
  NSString *name = [_aliases objectForKey: alias];
  return name != nil ? [self collectionNamed: name] : nil;
}

- (NSString *) aliasForCollection: (KCCollection *)collection
{
  NSArray *keys = [_aliases allKeysForObject: [collection name]];
  return [keys count] > 0
    ? [[keys sortedArrayUsingSelector: @selector(compare:)] objectAtIndex: 0]
    : nil;
}

- (BOOL) saveAliases: (NSError **)error
{
  NSData *data = [NSPropertyListSerialization dataWithPropertyList: _aliases
    format: NSPropertyListXMLFormat_v1_0 options: 0 error: NULL];
  return [self writeData: data
                  toPath: [_directory stringByAppendingPathComponent: KCAliasesFile]
                   error: error];
}

- (void) postChangeAdded: (KCCollection *)added removed: (KCCollection *)removed
{
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (added != nil)
    [info setObject: added forKey: KCAddedCollectionKey];
  if (removed != nil)
    [info setObject: removed forKey: KCRemovedCollectionKey];
  [[NSNotificationCenter defaultCenter]
    postNotificationName: KCKeyringDidChangeCollectionsNotification
                  object: self userInfo: info];
}

- (BOOL) setAlias: (NSString *)alias
    forCollection: (KCCollection *)collection
            error: (NSError **)error
{
  if (collection != nil)
    [_aliases setObject: [collection name] forKey: alias];
  else
    [_aliases removeObjectForKey: alias];
  if (![self saveAliases: error])
    return NO;
  [self postChangeAdded: nil removed: nil];
  return YES;
}

/* Collection names become D-Bus object path elements, which only allow
 * [A-Za-z0-9_]. */
- (NSString *) uniqueNameForLabel: (NSString *)label
{
  NSMutableString *base = [NSMutableString string];
  NSString *lower = [label lowercaseString];
  NSString *candidate;
  NSUInteger i;
  unsigned n = 2;

  for (i = 0; i < [lower length]; i++)
    {
      unichar ch = [lower characterAtIndex: i];
      if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_')
        [base appendFormat: @"%C", ch];
      else
        [base appendString: @"_"];
    }
  if ([base length] == 0)
    [base setString: @"keyring"];

  candidate = base;
  while ([self collectionNamed: candidate] != nil
    || [[NSFileManager defaultManager] fileExistsAtPath: [self pathForName: candidate]])
    candidate = [NSString stringWithFormat: @"%@_%u", base, n++];
  return candidate;
}

- (KCCollection *) createCollectionWithLabel: (NSString *)label
                                    password: (NSString *)password
                                       error: (NSError **)error
{
  KCCollection *c = [[KCCollection alloc]
    initWithName: [self uniqueNameForLabel: label] label: label password: password];

  if (![self saveCollection: c error: error])
    return nil;
  [_collections addObject: c];
  [self postChangeAdded: c removed: nil];
  return c;
}

- (BOOL) deleteCollection: (KCCollection *)collection error: (NSError **)error
{
  NSString *path = [self pathForName: [collection name]];
  NSArray *aliases = [_aliases allKeysForObject: [collection name]];

  if (unlink([path fileSystemRepresentation]) != 0 && errno != ENOENT)
    {
      if (error != NULL)
        *error = KCIOError(path, @"delete");
      return NO;
    }
  [_collections removeObjectIdenticalTo: collection];
  if ([aliases count] > 0)
    {
      [_aliases removeObjectsForKeys: aliases];
      if (![self saveAliases: error])
        return NO;
    }
  [self postChangeAdded: nil removed: collection];
  return YES;
}

- (BOOL) saveCollection: (KCCollection *)collection error: (NSError **)error
{
  return [self writeData: [collection fileData]
                  toPath: [self pathForName: [collection name]]
                   error: error];
}

@end
