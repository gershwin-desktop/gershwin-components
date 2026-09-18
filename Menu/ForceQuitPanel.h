/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* Lists the running applications and ends the selected one immediately,
 * for applications that no longer respond to Quit. */
@interface ForceQuitPanelController : NSWindowController

+ (instancetype)sharedController;

/* Target of the Command menu item and the global shortcut. */
- (void)showPanel:(id)sender;

@end
