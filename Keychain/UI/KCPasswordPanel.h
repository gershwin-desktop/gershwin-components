/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class KCPasswordPanel;

/* Returns nil to accept, or a message shown in the panel, which stays open
 * for another try. */
typedef NSString *(^KCPasswordValidator)(KCPasswordPanel *panel);

/* A non-modal password panel. Non-modal on purpose: it is opened while a
 * D-Bus client waits, and a modal loop would re-enter libdbus dispatch. */
@interface KCPasswordPanel : NSObject <NSWindowDelegate>

/* newPassword asks twice and refuses a mismatch or an empty password;
 * askName adds a Name field (for a new keychain). */
- (instancetype) initWithTitle: (NSString *)title
                       message: (NSString *)message
                   newPassword: (BOOL)newPassword
                       askName: (BOOL)askName
                     validator: (KCPasswordValidator)validator
                    completion: (void (^)(BOOL accepted))completion;

- (NSString *) password;
- (NSString *) name;
- (NSPanel *) panel;

- (void) show;
/* Closes without calling the completion. */
- (void) close;

@end
