/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class KCKeychainWindowController;
@class KCCollection;
@class KCItem;

/* Shows the selected item's details. The password stays hidden until the
 * user confirms with the keychain password; the name and a revealed
 * password can be edited and saved. */
@interface KCItemInspector : NSWindowController

- (instancetype) initWithController: (KCKeychainWindowController *)controller;
- (void) setItem: (KCItem *)item collection: (KCCollection *)collection;

@end
