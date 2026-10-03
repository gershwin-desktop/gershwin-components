/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class TDMainWindowController;

@interface TDAppDelegate : NSObject
{
  TDMainWindowController *_mainWindowController;
}

- (void)showPreferences: (id)sender;

@end
