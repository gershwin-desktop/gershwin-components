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
  NSMutableDictionary<NSString *, NSNumber *> *_serverStatus; // Name -> SWBuildStatus, read before any fetch
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

  // Fail fast: ask the server what it says about the build of every branch
  // before anything is fetched. These are small requests that run side by
  // side and need nothing from git's network round trips, and a branch that is
  // building or has failed is known at once instead of after the slowest
  // fetch. The branch is named, not its tip commit: the tip is only known
  // after the fetch, and GitHub answers for a branch name as for a commit.
  [self preloadServerStatusForRepositories:repositories stopRequested:stopRequested];

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
          [repo setUnreachableReason:@"Check stopped before it finished"];
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
  NSString *fetchError = nil;
  if (![git fetchPruneOrigin:&fetchError]) {
    // A fetch that failed leaves origin/<branch> exactly where it was, so
    // every HEAD..origin/<branch> below would come back empty and the
    // repository would read as "no updates" - a claim, when in fact nothing
    // was checked. Say what happened instead, in git's own words, and stop
    // here so nothing downstream mistakes a stale ref for a current one.
    [repo setUnreachableReason:[NSString stringWithFormat:@"Couldn't fetch: %@",
      fetchError ?: @"git failed"]];
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
    // What the server said about the branch before the fetch, when it said
    // anything; the tip commit is asked for only if it did not.
    NSNumber *early = nil;
    @synchronized (self) { early = [_serverStatus objectForKey:[repo name]]; }
    if (early && [early integerValue] != SWBuildStatusUnknown) {
      [repo setBuildStatus:(SWBuildStatus)[early integerValue]];
    } else {
      NSString *tipSha = [[[repo commits] objectAtIndex:0] sha];
      [repo setBuildStatus:[_buildStatusClient statusForRepositoryNamed:[repo name] sha:tipSha]];
    }
  }
}

// The branch a repository is checked against, from what is already on disk:
// dev when asked for and known from the last fetch, else the default branch.
- (NSString *)branchToAskAboutForRepository:(SWRepository *)repo git:(SWGitTool *)git
{
  if (_useDevBranch && [git fullShaForRef:@"origin/dev"]) return @"dev";
  return [git defaultBranch];
}

- (void)preloadServerStatusForRepositories:(NSArray<SWRepository *> *)repositories
                              stopRequested:(BOOL (^)(void))stopRequested
{
  _serverStatus = [NSMutableDictionary dictionary];
  dispatch_semaphore_t limit = dispatch_semaphore_create(6);
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  dispatch_group_t group = dispatch_group_create();

  for (SWRepository *repo in repositories) {
    if ([repo isPinned]) continue;   // pins move with gershwin-developer, not with a build
    dispatch_group_async(group, queue, ^{
      dispatch_semaphore_wait(limit, DISPATCH_TIME_FOREVER);
      if (!(stopRequested && stopRequested())) {
        NSString *branch = [self branchToAskAboutForRepository:repo
                                                            git:[self gitToolForRepository:repo]];
        // A branch that is where this checkout is has nothing to install, so
        // its build does not matter: one request less against the rate limit.
        SWGitTool *git = [self gitToolForRepository:repo];
        NSString *tip = branch ? [git remoteTipOfBranch:branch] : nil;
        if (branch && !(tip && [tip isEqualToString:[git fullShaForRef:@"HEAD"]])) {
          SWBuildStatus status = [self->_buildStatusClient statusForRepositoryNamed:[repo name] sha:branch];
          @synchronized (self) { [self->_serverStatus setObject:@(status) forKey:[repo name]]; }
        }
      }
      dispatch_semaphore_signal(limit);
    });
  }
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
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
