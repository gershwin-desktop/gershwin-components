/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKStore.h"
#import "DKList.h"
#import "DKTask.h"
#import "DKMarkdownCodec.h"
#import "DKLineMerge.h"
#import "DKGistClient.h"
#import "DKURLConnectionTransport.h"
#import "DKPreferences.h"

NSString * const DKStoreErrorDomain = @"DKStoreErrorDomain";

static NSString * const DKListsSubdir = @"Lists";
static NSString * const DKBaseSubdir = @"Base";
static NSString * const DKManifestFilename = @"manifest.plist";

@interface DKStore (Private)
- (NSString *)cacheDirNamed: (NSString *)subdir;
- (NSString *)pathForFilename: (NSString *)filename inSubdir: (NSString *)subdir;
- (NSString *)stringFromFilename: (NSString *)filename inSubdir: (NSString *)subdir;
- (void)writeString: (NSString *)s toFilename: (NSString *)filename inSubdir: (NSString *)subdir;
- (void)loadManifest;
- (void)saveManifest;
- (void)loadListsFromCache;
- (BOOL)ensureClientWithError: (NSError **)error;
- (BOOL)applyRemoteFiles: (NSDictionary *)remoteFiles;
@end

@implementation DKStore

+ (instancetype)sharedStore
{
  static DKStore *instance = nil;

  if (instance == nil)
    {
      instance = [[self alloc] init];
    }
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      NSArray *libPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
      NSString *libPath = ([libPaths count] > 0) ? [libPaths objectAtIndex: 0]
                                                  : [@"~/Library" stringByExpandingTildeInPath];

      _cacheDir = [[libPath stringByAppendingPathComponent: @"Docket"] retain];
      _lists = [[NSMutableArray alloc] init];
      _conflictedListNames = [[NSArray alloc] init];
      [self loadManifest];
      [self loadListsFromCache];
    }
  return self;
}

- (void)dealloc
{
  [_lists release];
  [_cacheDir release];
  [_lastUpdatedAt release];
  [_conflictedListNames release];
  [_client release];
  [super dealloc];
}

- (NSMutableArray *)lists
{
  return _lists;
}

- (NSArray *)conflictedListNames
{
  return _conflictedListNames;
}

- (DKList *)addListNamed: (NSString *)name
{
  DKList *list = [DKList listWithName: name];

  [_lists addObject: list];
  [self saveListLocally: list];
  return list;
}

- (void)removeList: (DKList *)list
{
  [_lists removeObject: list];
  [[NSFileManager defaultManager] removeItemAtPath: [self pathForFilename: [list gistFilename] inSubdir: DKListsSubdir]
                                              error: NULL];
  [self saveManifest];
}

- (void)saveListLocally: (DKList *)list
{
  NSString *content = [DKMarkdownCodec markdownFromList: list];

  [self writeString: content toFilename: [list gistFilename] inSubdir: DKListsSubdir];
  [self saveManifest];
}

- (void)persistListOrder
{
  [self saveManifest];
}

- (BOOL)pullWithError: (NSError **)error
{
  NSDictionary *remote;

  if (![self ensureClientWithError: error])
    {
      return NO;
    }

  remote = [_client fetchGistWithError: error];
  if (remote == nil)
    {
      return NO;
    }

  [self applyRemoteFiles: [remote objectForKey: @"files"]];
  [_lastUpdatedAt release];
  _lastUpdatedAt = [[remote objectForKey: @"updated_at"] copy];
  [self saveManifest];
  return YES;
}

- (BOOL)pushWithError: (NSError **)error
{
  NSDictionary *remote;
  NSString *remoteUpdatedAt;
  NSMutableDictionary *filesToPush;
  NSString *filename;
  NSDictionary *after;

  if (![self ensureClientWithError: error])
    {
      return NO;
    }

  /* Never push blind: check whether the gist moved since our last pull,
   * and if it did, fold that remote state in first so our push cannot
   * silently overwrite it. */
  remote = [_client fetchGistWithError: error];
  if (remote == nil)
    {
      return NO;
    }
  remoteUpdatedAt = [remote objectForKey: @"updated_at"];
  if (_lastUpdatedAt == nil || ![remoteUpdatedAt isEqualToString: _lastUpdatedAt])
    {
      [self applyRemoteFiles: [remote objectForKey: @"files"]];
      [_lastUpdatedAt release];
      _lastUpdatedAt = [remoteUpdatedAt copy];
    }

  filesToPush = [NSMutableDictionary dictionary];
  for (DKList *list in _lists)
    {
      [filesToPush setObject: [DKMarkdownCodec markdownFromList: list] forKey: [list gistFilename]];
    }

  if (![_client updateGistFiles: filesToPush error: error])
    {
      return NO;
    }

  /* What we just pushed is now the agreed-on remote state; adopt it as
   * the merge base for the next pull. */
  for (filename in filesToPush)
    {
      [self writeString: [filesToPush objectForKey: filename] toFilename: filename inSubdir: DKBaseSubdir];
    }

  after = [_client fetchGistWithError: NULL];
  if (after != nil)
    {
      [_lastUpdatedAt release];
      _lastUpdatedAt = [[after objectForKey: @"updated_at"] copy];
    }
  [self saveManifest];
  return YES;
}

@end

@implementation DKStore (Private)

- (NSString *)cacheDirNamed: (NSString *)subdir
{
  NSString *dir = [_cacheDir stringByAppendingPathComponent: subdir];
  NSFileManager *fm = [NSFileManager defaultManager];

  if (![fm fileExistsAtPath: dir])
    {
      [fm createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
    }
  return dir;
}

- (NSString *)pathForFilename: (NSString *)filename inSubdir: (NSString *)subdir
{
  return [[self cacheDirNamed: subdir] stringByAppendingPathComponent: filename];
}

- (NSString *)stringFromFilename: (NSString *)filename inSubdir: (NSString *)subdir
{
  NSString *path = [self pathForFilename: filename inSubdir: subdir];
  NSString *content = [NSString stringWithContentsOfFile: path];

  return (content != nil) ? content : @"";
}

- (void)writeString: (NSString *)s toFilename: (NSString *)filename inSubdir: (NSString *)subdir
{
  NSString *path = [self pathForFilename: filename inSubdir: subdir];

  [s writeToFile: path atomically: YES];
}

- (void)loadManifest
{
  NSString *path = [_cacheDir stringByAppendingPathComponent: DKManifestFilename];
  NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile: path];

  _lastUpdatedAt = [[manifest objectForKey: @"UpdatedAt"] copy];
}

- (void)saveManifest
{
  NSMutableArray *order = [NSMutableArray array];
  NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
  DKList *list;

  for (list in _lists)
    {
      [order addObject: [list gistFilename]];
    }
  if (_lastUpdatedAt != nil)
    {
      [manifest setObject: _lastUpdatedAt forKey: @"UpdatedAt"];
    }
  [manifest setObject: order forKey: @"Order"];

  [self cacheDirNamed: @"."];
  [manifest writeToFile: [_cacheDir stringByAppendingPathComponent: DKManifestFilename] atomically: YES];
}

- (void)loadListsFromCache
{
  NSString *path = [_cacheDir stringByAppendingPathComponent: DKManifestFilename];
  NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile: path];
  NSArray *order = [manifest objectForKey: @"Order"];
  NSString *listsDir = [self cacheDirNamed: DKListsSubdir];
  NSMutableSet *seen = [NSMutableSet set];
  NSString *filename;
  NSArray *onDisk;

  for (filename in order)
    {
      NSString *content = [self stringFromFilename: filename inSubdir: DKListsSubdir];
      NSString *name = [filename stringByDeletingPathExtension];

      [_lists addObject: [DKMarkdownCodec listFromMarkdown: content name: name]];
      [seen addObject: filename];
    }

  onDisk = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: listsDir error: NULL];
  for (filename in onDisk)
    {
      if ([seen containsObject: filename] || ![[filename pathExtension] isEqualToString: @"md"])
        {
          continue;
        }
      NSString *content = [self stringFromFilename: filename inSubdir: DKListsSubdir];
      NSString *name = [filename stringByDeletingPathExtension];

      [_lists addObject: [DKMarkdownCodec listFromMarkdown: content name: name]];
    }
}

- (BOOL)ensureClientWithError: (NSError **)error
{
  NSString *gistId = [DKPreferences gistId];
  NSString *token = [DKPreferences token];

  if ([gistId length] == 0 || [token length] == 0)
    {
      if (error != NULL)
        {
          *error = [NSError errorWithDomain: DKStoreErrorDomain
                                        code: -1
                                    userInfo: [NSDictionary dictionaryWithObject:
                                      @"Set a gist ID and a GitHub personal access token in Preferences first."
                                                                           forKey: NSLocalizedDescriptionKey]];
        }
      return NO;
    }

  {
    /* Rebuilt on every sync rather than cached: cheap (just headers/URL
     * strings until a request is actually sent) and it means a token or
     * gist ID change in Preferences takes effect on the very next sync. */
    DKURLConnectionTransport *transport = [[[DKURLConnectionTransport alloc] init] autorelease];

    [_client release];
    _client = [[DKGistClient alloc] initWithGistId: gistId token: token transport: transport];
  }
  return YES;
}

- (BOOL)applyRemoteFiles: (NSDictionary *)remoteFiles
{
  NSMutableArray *conflicted = [NSMutableArray array];
  NSString *filename;

  for (filename in remoteFiles)
    {
      NSString *remoteContent = [remoteFiles objectForKey: filename];
      NSString *localContent = [self stringFromFilename: filename inSubdir: DKListsSubdir];
      NSString *baseContent = [self stringFromFilename: filename inSubdir: DKBaseSubdir];
      BOOL conflict = NO;
      NSString *merged = [DKLineMerge mergeBase: baseContent
                                           local: localContent
                                          remote: remoteContent
                                        conflict: &conflict];
      NSString *name = [filename stringByDeletingPathExtension];
      DKList *list = [DKMarkdownCodec listFromMarkdown: merged name: name];
      NSUInteger existingIndex = NSNotFound;
      NSUInteger i;

      [self writeString: merged toFilename: filename inSubdir: DKListsSubdir];
      [self writeString: remoteContent toFilename: filename inSubdir: DKBaseSubdir];
      if (conflict)
        {
          [conflicted addObject: filename];
        }

      for (i = 0; i < [_lists count]; i++)
        {
          if ([[[_lists objectAtIndex: i] gistFilename] isEqualToString: filename])
            {
              existingIndex = i;
              break;
            }
        }
      if (existingIndex != NSNotFound)
        {
          [_lists replaceObjectAtIndex: existingIndex withObject: list];
        }
      else
        {
          [_lists addObject: list];
        }
    }

  [_conflictedListNames release];
  _conflictedListNames = [conflicted copy];
  return ([conflicted count] == 0);
}

@end
