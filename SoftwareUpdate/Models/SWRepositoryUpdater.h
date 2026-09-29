/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWRepositoryUpdater - the "Update each repository" step (spec screen 5),
 * for one repository: stash -> checkout & pull (or checkout the pin) ->
 * patches -> build -> install -> re-apply stash. Runs as root (invoked by
 * the privileged helper); every step is logged via the repository's
 * SWGitTool log handler.
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"

typedef NS_ENUM(NSInteger, SWRepositoryUpdateOutcome) {
  SWRepositoryUpdateOutcomeUpdated = 0,       // succeeded, nothing left over
  SWRepositoryUpdateOutcomeStashKept,         // succeeded, but local changes stayed in the stash
  SWRepositoryUpdateOutcomeDiverged,          // local commits made a fast-forward impossible; skipped
  SWRepositoryUpdateOutcomeBuildFailed,       // patch or build failed; rolled back
  SWRepositoryUpdateOutcomeInstallFailed,     // install failed; rolled back
};

@interface SWRepositoryUpdater : NSObject

// sourcesDirectory: Library/Sources under the gershwin-developer checkout.
// installScriptPath: Library/Scripts/install-system-domain.sh.
// stepHandler is called before each step for the progress window's status
// line, e.g. "Building gershwin-workspace (repository 2 of 6)" is composed
// by the caller from the verb this reports.
- (instancetype)initWithSourcesDirectory:(NSString *)sourcesDirectory
                       installScriptPath:(NSString *)installScriptPath
                              logHandler:(void (^)(NSString *line))logHandler;

- (SWRepositoryUpdateOutcome)updateRepository:(SWRepository *)repository
                                  targetBranch:(NSString *)targetBranch
                                    stepHandler:(void (^)(NSString *stepVerb))stepHandler;

// The "Rebuild" action: compile and install the code that is already checked
// out, touching no git state at all. Nothing is stashed, no branch is
// switched, no patch is applied - the working copy is built exactly as it
// stands and installed over /System. Use it when the check found no updates
// but the installed software is stale or broken (a hand-edited file, a failed
// earlier build, a library that was rebuilt out of band).
//
// Deliberately not -updateRepository: with the git steps skipped by a flag:
// the two have nothing else in common, and sharing one method would mean every
// rebuild ran a checkout and a stash/pop it does not want.
- (SWRepositoryUpdateOutcome)rebuildRepository:(SWRepository *)repository
                                   stepHandler:(void (^)(NSString *stepVerb))stepHandler;

// Valid after -updateRepository:... returns SWRepositoryUpdateOutcomeStashKept
// for this repository: the files git reported as conflicted when the stash
// could not be popped, for the stash alert (spec screen 6).
- (NSArray<NSString *> *)conflictedPathsForRepositoryNamed:(NSString *)name;

@end
