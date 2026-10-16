/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "KCSecretService.h"

/* Owns the keyring, the Secret Service and the main window, and answers
 * the service's password prompts with panels. */
@interface KCAppDelegate : NSObject <NSApplicationDelegate, KCPasswordRequester>

- (IBAction) showKeychainWindow: (id)sender;

@end
