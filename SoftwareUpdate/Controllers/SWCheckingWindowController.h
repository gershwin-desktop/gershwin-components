/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWCheckingWindowController - spec screen 1: shown on launch and for
 * "Check Now". An indeterminate progress indicator plus a status line
 * ("Fetching <repo> from origin (n of N)") and a Stop button.
 */

#import <AppKit/AppKit.h>

@class SWCheckingWindowController;

@protocol SWCheckingWindowControllerDelegate <NSObject>
- (void)checkingWindowControllerDidClickStop:(SWCheckingWindowController *)controller;
@end

@interface SWCheckingWindowController : NSWindowController

@property (nonatomic, weak) id<SWCheckingWindowControllerDelegate> delegate;

- (void)setStatusRepositoryName:(NSString *)name index:(NSUInteger)index total:(NSUInteger)total;

@end
