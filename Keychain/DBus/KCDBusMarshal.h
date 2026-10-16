/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <dbus/dbus.h>

/* D-Bus values as Objective-C objects:
 *   s, g          NSString
 *   o             KCDBusObjectPath
 *   b, y, n..d    NSNumber
 *   ay            NSData
 *   a{..}         NSDictionary
 *   other arrays  NSArray
 *   (..)          NSArray, one element per member
 *   v             KCDBusVariant
 * Writing is driven by an explicit signature, never guessed from the objects,
 * because the Secret Service types (a{sv}, (oayays), ao) must be exact for
 * libsecret to accept a reply. */

@interface KCDBusObjectPath : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *string;
+ (instancetype) pathWithString: (NSString *)string;
@end

@interface KCDBusVariant : NSObject
@property (nonatomic, readonly, copy) NSString *signature;
@property (nonatomic, readonly, strong) id value;
+ (instancetype) variantWithSignature: (NSString *)signature value: (id)value;
@end

/* Appends values according to signature (one value per complete type).
 * Raises NSInvalidArgumentException when a value does not fit its type:
 * that is a bug in our own reply code, not a client error. */
void KCDBusAppendArguments(DBusMessage *message, NSString *signature, NSArray *values);

/* Reads all arguments of a message. */
NSArray *KCDBusReadArguments(DBusMessage *message);
