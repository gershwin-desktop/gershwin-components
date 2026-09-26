/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWMainWindowController - spec screen 2: the repositories-with-new-commits
 * window. Table + details split view, dev-branch switch, summary line, Quit
 * and the default "Update N Repositories" button.
 */

#import <AppKit/AppKit.h>
#import "SWRepository.h"

@class SWMainWindowController;

@protocol SWMainWindowControllerDelegate <NSObject>
- (void)mainWindowController:(SWMainWindowController *)controller
      didConfirmUpdateForRepositories:(NSArray<SWRepository *> *)repositories;
- (void)mainWindowControllerDidClickQuit:(SWMainWindowController *)controller;
// The dev-branch switch changed; recompute target branches/commits/build
// status for every non-pinned repository from data already fetched (no
// network) and call back with the same array, mutated in place.
- (void)mainWindowController:(SWMainWindowController *)controller
       useDevelopmentBranchDidChange:(BOOL)useDevBranch;
@end

@interface SWMainWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) id<SWMainWindowControllerDelegate> delegate;

// repositoriesWithUpdates: only repositories with something to install, in
// list order (already filtered/selected by SWSelectionRules).
// upToDateCount: repositories checked but with nothing new, for the summary
// line ("23 repositories are up to date").
- (void)setRepositories:(NSArray<SWRepository *> *)repositories
           upToDateCount:(NSUInteger)upToDateCount
        useDevelopmentBranch:(BOOL)useDevBranch;

@end
