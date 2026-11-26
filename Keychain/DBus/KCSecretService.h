/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "KCDBusConnection.h"

@class KCKeyring;

extern NSString * const KCSecretServiceBusName;
extern NSString * const KCSecretServicePath;

/* Asks the user for a password on behalf of a Prompt object. The panel must
 * not run a modal loop: it is opened from inside D-Bus dispatch, which
 * libdbus does not allow to re-enter.
 *
 * validator is called with each password the user confirms and returns nil
 * when it was accepted (the keyring is unlocked or created by then) or a
 * message to show while the panel stays open. completion runs once, with
 * NO when the user cancelled or the client dismissed the prompt. */
@protocol KCPasswordRequester <NSObject>
- (id) requestPasswordWithTitle: (NSString *)title
                        message: (NSString *)message
                    newPassword: (BOOL)isNew
                      validator: (NSString *(^)(NSString *password))validator
                     completion: (void (^)(BOOL accepted))completion;
/* Closes a panel returned above without calling its completion. */
- (void) cancelPasswordRequest: (id)request;
@end

/* The freedesktop.org Secret Service (org.freedesktop.secrets) on top of
 * a KCKeyring: Service, Collection, Item, Session and Prompt objects, the
 * Properties and Introspectable interfaces, and the change signals. */
@interface KCSecretService : NSObject <KCDBusObjectHandler>

- (instancetype) initWithKeyring: (KCKeyring *)keyring
                      connection: (KCDBusConnection *)connection
                       requester: (id<KCPasswordRequester>)requester;

/* Registers the objects and takes the bus name. */
- (BOOL) start: (NSError **)error;

@end
