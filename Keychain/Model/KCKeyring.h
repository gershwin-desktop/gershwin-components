/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class KCCollection;

/* Posted when a keyring was added or removed, or an alias moved. */
extern NSString * const KCKeyringDidChangeCollectionsNotification;
extern NSString * const KCAddedCollectionKey;
extern NSString * const KCRemovedCollectionKey;

/* All keyrings of the user: one <name>.keyring file each plus Aliases.plist
 * in one directory. Callers save right after each change and report a
 * failed save to whoever asked for the change, so no client is ever told a
 * credential was stored when it was not. */
@interface KCKeyring : NSObject

/* Keyrings in the user domain's Library (~/Library on Gershwin). */
+ (NSString *) defaultDirectory;

- (instancetype) initWithDirectory: (NSString *)directory;

/* Reads every keyring file. Fails on the first file that cannot be read
 * instead of silently hiding a keyring the user expects to be there. */
- (BOOL) load: (NSError **)error;

- (NSArray *) collections;
- (KCCollection *) collectionNamed: (NSString *)name;

- (KCCollection *) collectionForAlias: (NSString *)alias;
- (NSString *) aliasForCollection: (KCCollection *)collection;
/* A nil collection removes the alias. */
- (BOOL) setAlias: (NSString *)alias
    forCollection: (KCCollection *)collection
            error: (NSError **)error;

/* The name is derived from the label ("Login" -> "login") and made unique. */
- (KCCollection *) createCollectionWithLabel: (NSString *)label
                                    password: (NSString *)password
                                       error: (NSError **)error;
- (BOOL) deleteCollection: (KCCollection *)collection error: (NSError **)error;

/* Writes the collection file (mode 0600, atomically). */
- (BOOL) saveCollection: (KCCollection *)collection error: (NSError **)error;

@end
