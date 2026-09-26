/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWCompletionWindowController - spec screen 7: one row per repository
 * processed in this run, in run order. The right-hand column is empty for
 * normal results and only shows exceptions. Offers Restart/Later when
 * anything needing a restart was installed; otherwise a single Quit.
 */

#import <AppKit/AppKit.h>
#import "SWRepositoryUpdater.h"

@interface SWCompletionResultRow : NSObject
@property (nonatomic, copy) NSString *repositoryName;
@property (nonatomic) SWRepositoryUpdateOutcome outcome;
@property (nonatomic) BOOL restartRequired;
@end

@class SWCompletionWindowController;

@protocol SWCompletionWindowControllerDelegate <NSObject>
- (void)completionWindowControllerDidClickRestart:(SWCompletionWindowController *)controller;
- (void)completionWindowControllerDidClickLaterOrQuit:(SWCompletionWindowController *)controller;
@end

@interface SWCompletionWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, weak) id<SWCompletionWindowControllerDelegate> delegate;

- (void)setResults:(NSArray<SWCompletionResultRow *> *)results;

@end
