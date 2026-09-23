/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWUpdateChecker - the "check" step (spec screen 1): fetches every
 * repository from origin, in list order, and fills in each SWRepository's
 * branch, commit and build-status fields. Runs off the main thread; call it
 * from a background queue and hop back to the main thread in the callbacks.
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"
#import "SWGitTool.h"
#import "SWGitHubBuildStatus.h"

@interface SWUpdateChecker : NSObject

// sourcesDirectory is Library/Sources under the gershwin-developer checkout
// (each repository's working copy is sourcesDirectory/<Name>).
// gitToolFactory == nil uses real SWGitTool instances; buildStatusClient ==
// nil creates a real SWGitHubBuildStatus. Both are injectable for testing.
- (instancetype)initWithSourcesDirectory:(NSString *)sourcesDirectory
                             useDevBranch:(BOOL)useDevBranch
                           gitToolFactory:(SWGitTool * (^)(NSString *repositoryPath))gitToolFactory
                        buildStatusClient:(SWGitHubBuildStatus *)buildStatusClient
                               logHandler:(SWGitLogLine)logHandler;

// Checks each repository in order. progress is called before each repository
// is fetched (for "Fetching <repo> from origin (n of N)"); stopRequested is
// polled between repositories so Stop can cut the run short. Every
// repository's fields are updated in place; completion receives the subset
// that actually has something to install, in list order, plus whether any
// repository could be reached at all.
- (void)checkRepositories:(NSArray<SWRepository *> *)repositories
             stopRequested:(BOOL (^)(void))stopRequested
                  progress:(void (^)(SWRepository *repository, NSUInteger index, NSUInteger total))progress
                completion:(void (^)(NSArray<SWRepository *> *repositoriesWithUpdates, BOOL anyReachable))completion;

// Toggling "Use Development branch" needs no network: both branches were
// already fetched by -checkRepositories:..., so this just re-reads the
// already-local origin/<target> refs for the new target and re-applies
// selection. Safe to call on a background thread; touches no network.
- (void)recomputeTargetBranchForRepositories:(NSArray<SWRepository *> *)repositories
                                  useDevBranch:(BOOL)useDevBranch;

@end
