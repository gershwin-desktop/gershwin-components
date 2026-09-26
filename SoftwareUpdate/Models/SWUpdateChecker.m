/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWUpdateChecker.h"
#import "SWSelectionRules.h"
#import "SWRepositoryList.h"

@interface SWUpdateChecker ()
{
  NSString *_sourcesDirectory;
  BOOL _useDevBranch;
  SWGitTool * (^_gitToolFactory)(NSString *);
  SWGitHubBuildStatus *_buildStatusClient;
  SWGitLogLine _logHandler;
  NSString *_incomingRepositoriesPlistTarget; // the branch its pins were read from, so we only read it once
  NSDictionary<NSString *, NSString *> *_incomingPins; // Name -> Pin, from the incoming gershwin-developer
  NSString *_localFailureReason;
}
@property (nonatomic, copy, readwrite) NSString *localFailureReason;
@end

@implementation SWUpdateChecker

@synthesize localFailureReason = _localFailureReason;

- (instancetype)initWithSourcesDirectory:(NSString *)sourcesDirectory
                             useDevBranch:(BOOL)useDevBranch
                           gitToolFactory:(SWGitTool * (^)(NSString *))gitToolFactory
                        buildStatusClient:(SWGitHubBuildStatus *)buildStatusClient
                               logHandler:(SWGitLogLine)logHandler
{
  self = [super init];
  if (self) {
    _sourcesDirectory = [sourcesDirectory copy];
    _useDevBranch = useDevBranch;
    _gitToolFactory = gitToolFactory ? [gitToolFactory copy] : nil;
    _buildStatusClient = buildStatusClient ?: [[SWGitHubBuildStatus alloc] initWithFetcher:nil];
    _logHandler = logHandler ? (SWGitLogLine)[logHandler copy] : ^(NSString *line) {};
  }
  return self;
}

- (NSString *)pathForRepository:(SWRepository *)repository
{
  return [_sourcesDirectory stringByAppendingPathComponent:[repository name]];
}

- (SWGitTool *)gitToolForRepository:(SWRepository *)repository
{
  NSString *path = [self pathForRepository:repository];
  SWGitTool *tool = _gitToolFactory ? _gitToolFactory(path) : [[SWGitTool alloc] initWithRepositoryPath:path];
  [tool setLogHandler:_logHandler];
  return tool;
}

// Every repository's fetch is its own network round-trip, and none of them
// depends on another's outcome - except that a pinned library's "did the
// incoming pin move" check reads gershwin-developer's just-fetched refs
// (see -incomingPinForRepositoryNamed:). So gershwin-developer is always
// fetched first, on its own; everything else fans out onto a capped number
// of concurrent background jobs, which is where nearly all the wall-clock
// time (waiting on git's network I/O) actually overlaps.
- (void)checkRepositories:(NSArray<SWRepository *> *)repositories
             stopRequested:(BOOL (^)(void))stopRequested
                  progress:(void (^)(SWRepository *, NSUInteger, NSUInteger))progress
                completion:(void (^)(NSArray<SWRepository *> *, BOOL))completion
{
  static const NSUInteger kMaxConcurrentFetches = 6;
  NSUInteger total = [repositories count];

  // /Developer is meant to be shared between users, so its checkouts often
  // belong to somebody other than whoever runs this app - git then refuses
  // to touch them at all, which used to read back to the user as "can't
  // reach GitHub". Ask sudo for the permission once, before the first git
  // runs: one prompt for the whole check instead of one per repository (the
  // fetches below run in parallel), nothing at all when the checkouts are
  // this user's own, and a declined prompt reported as what it is rather
  // than as a check that ran and failed.
  self.localFailureReason = nil;
  NSMutableArray<NSString *> *repositoryPaths = [NSMutableArray array];
  for (SWRepository *repo in repositories) {
    [repositoryPaths addObject:[self pathForRepository:repo]];
  }
  NSString *elevationReason = nil;
  if (![SWGitTool prepareElevationForPaths:repositoryPaths
                                logHandler:_logHandler
                                    reason:&elevationReason]) {
    self.localFailureReason = elevationReason;
    for (SWRepository *repo in repositories) {
      [repo setUnreachableReason:@"Couldn't get permission to run git"];
    }
    if (completion) completion(@[], NO);
    return;
  }

  NSMutableArray<SWRepository *> *remaining = [repositories mutableCopy];
  __block NSUInteger completedCount = 0;
  __block BOOL anyReachable = NO;
  NSLock *stateLock = [[NSLock alloc] init];

  void (^reportDone)(SWRepository *) = ^(SWRepository *repo) {
    [stateLock lock];
    completedCount++;
    if ([repo isReachable]) anyReachable = YES;
    NSUInteger reportedIndex = completedCount;
    [stateLock unlock];
    if (progress) progress(repo, reportedIndex, total);
  };

  if ([remaining count] > 0 && [[[remaining firstObject] name] isEqualToString:@"gershwin-developer"]) {
    SWRepository *developer = remaining[0];
    [remaining removeObjectAtIndex:0];
    [self checkOneRepository:developer];
    reportDone(developer);
  }

  // Precompute the incoming-pins map now, synchronously, while it is still
  // just this one thread - it is read (never written) by every pinned
  // library's check below, which is what makes reading it lock-free once
  // the parallel phase starts. Skipped when nothing pinned remains, since
  // it costs its own git operations against gershwin-developer.
  for (SWRepository *repo in remaining) {
    if ([repo isPinned]) {
      [self preloadIncomingPins];
      break;
    }
  }

  if (!(stopRequested && stopRequested()) && [remaining count] > 0) {
    dispatch_semaphore_t concurrencyLimit = dispatch_semaphore_create((long)kMaxConcurrentFetches);
    dispatch_queue_t workQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();

    for (SWRepository *repo in remaining) {
      dispatch_group_async(group, workQueue, ^{
        dispatch_semaphore_wait(concurrencyLimit, DISPATCH_TIME_FOREVER);
        if (!(stopRequested && stopRequested())) {
          [self checkOneRepository:repo];
        } else {
          [repo setUnreachableReason:@"Couldn't check"];
        }
        dispatch_semaphore_signal(concurrencyLimit);
        reportDone(repo);
      });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  }

  [SWSelectionRules applyDefaultSelectionToRepositories:repositories];

  NSMutableArray *withUpdates = [NSMutableArray array];
  for (SWRepository *repo in repositories) {
    if ([repo hasUpdate]) [withUpdates addObject:repo];
  }

  if (completion) completion([withUpdates copy], anyReachable);
}

// Fetches and fills in every field for one repository. Safe to call
// concurrently for different repositories - each touches only its own
// working copy and its own SWRepository object; the one piece of state
// shared across calls (SWGitHubBuildStatus's cache) locks itself.
- (void)checkOneRepository:(SWRepository *)repo
{
  SWGitTool *git = [self gitToolForRepository:repo];
  if (![git fetchPruneOrigin]) {
    [repo setUnreachableReason:@"Couldn't check"];
    return;
  }

  [repo setCurrentBranch:[git currentBranch]];
  [repo setHasDevBranch:[git remoteHasBranch:@"dev"]];

  if ([repo isPinned]) {
    [self checkPinnedRepository:repo git:git];
  } else {
    [self checkBranchedRepository:repo git:git];
  }

  [repo setModifiedFileCount:[git modifiedFileCount]];
  [repo setDirty:[repo modifiedFileCount] > 0];
}

- (void)recomputeTargetBranchForRepositories:(NSArray<SWRepository *> *)repositories
                                  useDevBranch:(BOOL)useDevBranch
{
  _useDevBranch = useDevBranch;
  for (SWRepository *repo in repositories) {
    if ([repo isPinned] || ![repo isReachable]) continue;
    SWGitTool *git = [self gitToolForRepository:repo];
    [self checkBranchedRepository:repo git:git];
  }
  [SWSelectionRules applyDefaultSelectionToRepositories:repositories];
}

- (void)checkBranchedRepository:(SWRepository *)repo git:(SWGitTool *)git
{
  NSString *target = ([repo hasDevBranch] && _useDevBranch) ? @"dev" : [git defaultBranch];
  [repo setTargetBranch:target];
  if (!target) return;

  [repo setCommits:[git commitsBehindTarget:target]];

  if ([repo commitCount] > 0) {
    NSString *tipSha = [[[repo commits] objectAtIndex:0] sha];
    [repo setBuildStatus:[_buildStatusClient statusForRepositoryNamed:[repo name] sha:tipSha]];
  }
}

// Pinned upstream libraries never follow a branch: they are listed only
// when the incoming gershwin-developer moves their pin away from the
// commit currently checked out. The pins are read from the incoming
// version of gershwin-developer (git show origin/<target>:Repositories.plist)
// so the check already reflects a pin bump that has not been pulled yet.
- (void)checkPinnedRepository:(SWRepository *)repo git:(SWGitTool *)git
{
  [repo setTargetBranch:nil]; // pinned libraries do not track a branch

  NSString *incomingPin = [self incomingPinForRepositoryNamed:[repo name]];
  if (!incomingPin) return;

  NSString *fullHead = [git fullShaForRef:@"HEAD"];
  NSString *fullIncomingPin = [git fullShaForRef:incomingPin];
  if (!fullHead || !fullIncomingPin) return;

  BOOL advanced = ![fullHead isEqualToString:fullIncomingPin];
  [repo setPinAdvanced:advanced];
  if (advanced) [repo setPin:incomingPin];
}

// Reads gershwin-developer's incoming Repositories.csv and caches the
// Name -> Pin mapping it declares. Idempotent (a second call is a no-op),
// but not safe to call concurrently from multiple threads - callers that
// might run pinned-library checks in parallel must call this once,
// synchronously, before fanning out (see -checkRepositories:...).
- (void)preloadIncomingPins
{
  if (_incomingPins) return;

  NSString *developerPath = [_sourcesDirectory stringByAppendingPathComponent:@"gershwin-developer"];
  SWGitTool *developerGit = _gitToolFactory ? _gitToolFactory(developerPath)
                                             : [[SWGitTool alloc] initWithRepositoryPath:developerPath];
  [developerGit setLogHandler:_logHandler];

  NSString *target = _useDevBranch && [developerGit remoteHasBranch:@"dev"]
                        ? @"dev" : [developerGit defaultBranch];
  NSData *data = target ? [developerGit showFileAtRef:[NSString stringWithFormat:@"origin/%@", target]
                                                   path:@"Library/Repositories.csv"]
                         : nil;
  NSMutableDictionary *pins = [NSMutableDictionary dictionary];
  if (data) {
    NSArray<SWRepository *> *incoming = [SWRepositoryList repositoriesFromCSVData:data error:NULL];
    for (SWRepository *entry in incoming) {
      if ([entry pin]) [pins setObject:[entry pin] forKey:[entry name]];
    }
  }
  _incomingPins = [pins copy];
}

- (NSString *)incomingPinForRepositoryNamed:(NSString *)name
{
  [self preloadIncomingPins];
  return [_incomingPins objectForKey:name];
}

@end
