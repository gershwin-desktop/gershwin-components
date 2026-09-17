/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemandController - Controller for placeholder installer apps.
 *
 * Supports two resource formats:
 *   1. Install.plist  - our plist format (preferred)
 *   2. packages + executable text files - helloSystem legacy format
 */

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import "../GWPackageManager.h"
#import "../GWPackageInstallSpec.h"

@interface OnDemandController : NSObject <NSApplicationDelegate, GWInstallProgressHandler>
{
  NSWindow *_window;
  NSProgressIndicator *_spinner;
  NSTextField *_statusField;
  NSButton *_cancelButton;

  GWPackageManager *_pm;
  GWPackageInstallSpec *_spec;
  NSString *_commandPath;
  NSString *_appName;
}

// Read the install spec from the app bundle (plist or text files)
- (BOOL)setupFromBundle;

// Check if the target command is already available without showing a window
- (BOOL)commandIsAvailable;

// Launch the command and exit the app (no GUI shown)
- (BOOL)launchAndExit;

// Show the progress window
- (void)showWindow;

// Install packages then launch (call after showWindow)
- (void)performInstallAndLaunch;

@end
