/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* One stored credential. Attributes are the lookup keys clients search by
 * (libsecret schemas put "service"/"account", git "protocol"/"server"/"user"
 * there); the secret itself is opaque bytes. */
@interface KCItem : NSObject <NSSecureCoding>

/* Unique inside its collection; also the last D-Bus object path component,
 * so it only ever contains [A-Za-z0-9_]. */
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSDictionary *attributes;
@property (nonatomic, copy) NSData *secret;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, strong) NSDate *created;
@property (nonatomic, strong) NSDate *modified;

- (instancetype) initWithIdentifier: (NSString *)identifier;

- (BOOL) matchesAttributes: (NSDictionary *)query;

/* What the item list shows as "Service" and "Account", picked from the
 * attribute names common clients use, so items stored by different tools
 * read the same way. */
- (NSString *) displayService;
- (NSString *) displayAccount;

@end
