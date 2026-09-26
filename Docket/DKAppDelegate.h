/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DKMainWindowController;

@interface DKAppDelegate : NSObject
{
  DKMainWindowController *_mainWindowController;
}

- (void)showPreferences: (id)sender;

@end
