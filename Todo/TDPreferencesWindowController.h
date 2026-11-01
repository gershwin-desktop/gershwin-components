/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/*
 * The one panel Todo needs: which gist to sync with, and the personal
 * access token to authenticate as. See TDPreferences.h for where these
 * are stored today (NSUserDefaults; Keychain.app will hold the token
 * once it exists).
 */
@interface TDPreferencesWindowController : NSObject
{
  NSWindow *_window;
  NSTextField *_gistIdField;
  NSSecureTextField *_tokenField;
}

+ (instancetype)sharedController;
- (void)showWindow;

@end
