/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PreferencesController_h
#define PreferencesController_h

#import <AppKit/AppKit.h>

/// UserDefaults keys
extern NSString *const PrefKeyYTDLPFormat;
extern NSString *const PrefKeyYTDLPPath;

/**
 * PreferencesController
 *
 * A simple preferences panel (nib-less) for configuring yt-dlp behaviour:
 *   - Stream quality / format selector
 *   - yt-dlp binary path
 *
 * Preferences are persisted via NSUserDefaults so they survive app restarts.
 * The controller is a one-shot window - call showPreferencesWindow: to
 * display it modally.
 */
@interface PreferencesController : NSObject
{
    NSPanel *_panel;
    NSPopUpButton *_formatPopUp;
    NSTextField *_pathField;
    NSTextField *_statusLabel;
    NSButton *_checkButton;
}

/// Show the preferences window (modal on the given window).
- (void)showPreferencesWindow:(NSWindow *)parentWindow;

/// @return The currently-configured yt-dlp format string from UserDefaults.
+ (NSString *)selectedFormat;

/// @return The path to the yt-dlp binary from UserDefaults.
+ (NSString *)ytdlpPath;

/// Open the preferences panel programmatically (IBAction for menu item).
- (IBAction)openPreferences:(id)sender;

@end

#endif /* PreferencesController_h */
