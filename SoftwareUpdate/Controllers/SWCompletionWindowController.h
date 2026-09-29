/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWCompletionWindowController - spec screen 7: one row per repository
 * processed in this run, in run order. The right-hand column is empty for
 * normal results and only shows exceptions. Offers Restart/Later when
 * anything needing a restart was installed; otherwise a single Quit.
 *
 * What the headline says, and whether a restart is offered, is decided by
 * SWCompletionSummary rather than here, so the wording can be tested without a
 * window server.
 */

#import <AppKit/AppKit.h>
#import "SWCompletionSummary.h"

@class SWCompletionWindowController;

@protocol SWCompletionWindowControllerDelegate <NSObject>
- (void)completionWindowControllerDidClickRestart:(SWCompletionWindowController *)controller;
- (void)completionWindowControllerDidClickLaterOrQuit:(SWCompletionWindowController *)controller;
@end

@interface SWCompletionWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) id<SWCompletionWindowControllerDelegate> delegate;

- (void)setResults:(NSArray<SWCompletionResultRow *> *)results;

// Whether this run was the "Rebuild" action rather than an update. Only the
// wording changes: the table, the restart rule and the buttons are identical,
// and it is always set before -setResults:.
@property (nonatomic) BOOL rebuild;

@end
