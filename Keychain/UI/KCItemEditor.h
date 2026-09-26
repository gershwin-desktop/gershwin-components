/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class KCKeychainWindowController;
@class KCCollection;

/* The "New Password Item" panel. Items it creates carry the attributes of
 * libsecret's generic schema (service, account), so command line tools and
 * libraries find them the same way as items they stored themselves. */
@interface KCItemEditor : NSWindowController

- (instancetype) initWithController: (KCKeychainWindowController *)controller;
- (void) beginForCollection: (KCCollection *)collection;

@end
