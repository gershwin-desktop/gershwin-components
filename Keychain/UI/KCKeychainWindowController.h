/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class KCKeyring;
@class KCCollection;
@class KCItem;

/* The main window: keychains on the left, the selected keychain's items on
 * the right, a search field, lock/unlock and add/remove. The menu actions
 * of the app go to this controller through the responder chain. */
@interface KCKeychainWindowController : NSWindowController
  <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

- (instancetype) initWithKeyring: (KCKeyring *)keyring;

- (KCCollection *) selectedCollection;
- (KCItem *) selectedItem;

/* Asks for the keychain's password before running block: showing or
 * copying a secret must be a deliberate act of the user, not a stray click. */
- (void) confirmPasswordForCollection: (KCCollection *)collection
                               reason: (NSString *)reason
                                 then: (void (^)(void))block;

/* Saves and reports a failure to the user; returns NO when not saved. */
- (BOOL) saveCollection: (KCCollection *)collection;

- (IBAction) toggleLock: (id)sender;
- (IBAction) lockAll: (id)sender;
- (IBAction) newItem: (id)sender;
- (IBAction) deleteItem: (id)sender;
- (IBAction) newKeychain: (id)sender;
- (IBAction) deleteKeychain: (id)sender;
- (IBAction) makeDefault: (id)sender;
- (IBAction) showInspector: (id)sender;
- (IBAction) copyPassword: (id)sender;
- (IBAction) performFindPanelAction: (id)sender;

@end
