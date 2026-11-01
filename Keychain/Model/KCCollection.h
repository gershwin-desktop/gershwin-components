/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class KCItem;

extern NSString * const KCKeyringErrorDomain;

typedef NS_ENUM(NSInteger, KCKeyringError) {
  KCKeyringErrorWrongPassword = 1,
  KCKeyringErrorCorruptFile,
  KCKeyringErrorUnsupportedFormat,
  KCKeyringErrorLocked,
  KCKeyringErrorIO
};

/* Posted by a collection whenever its items, label or lock state changed.
 * userInfo: KCChangeKindKey and, for item changes, KCChangedItemKey. */
extern NSString * const KCCollectionDidChangeNotification;
extern NSString * const KCChangeKindKey;
extern NSString * const KCChangedItemKey;
extern NSString * const KCChangeItemCreated;
extern NSString * const KCChangeItemDeleted;
extern NSString * const KCChangeItemChanged;
extern NSString * const KCChangeCollection;

/* PBKDF2-HMAC-SHA256 rounds for new keyrings (OWASP 2023 guidance). */
extern const unsigned KCDefaultKDFIterations;

/* A keyring: a named set of items encrypted as one file.
 *
 * File format (a binary property list, see Keychain/README.md):
 *   Format      "io.github.gershwin-desktop.keyring"
 *   Version     1
 *   Label, Created, Modified   shown while locked
 *   KDF         "PBKDF2-HMAC-SHA256", Iterations, Salt (16 bytes)
 *   Cipher      "AES-256-GCM", Nonce (12 bytes), Tag (16 bytes)
 *   Ciphertext  an NSKeyedArchiver archive of the item array
 *   Index       { item id: [SHA-256(salt | name | 0 | value), ...] }
 * The index lets SearchItems report items of a locked keyring (so clients
 * know to ask for an unlock) without revealing attribute values, the same
 * trade-off gnome-keyring makes with its hashed attributes. The header
 * fields are authenticated as GCM additional data. */
@interface KCCollection : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, readonly, strong) NSDate *created;
@property (nonatomic, readonly, strong) NSDate *modified;
@property (nonatomic, readonly, getter=isLocked) BOOL locked;
/* Rounds used the next time a password is set; tests lower it. */
@property (nonatomic) unsigned kdfIterations;

/* A new, unlocked, empty keyring protected by password. */
- (instancetype) initWithName: (NSString *)name
                        label: (NSString *)label
                     password: (NSString *)password;

/* A keyring read from disk. It starts locked. */
+ (instancetype) collectionWithName: (NSString *)name
                           fileData: (NSData *)data
                              error: (NSError **)error;

- (BOOL) unlockWithPassword: (NSString *)password error: (NSError **)error;
/* Checks a password without changing state, for confirming a reveal. */
- (BOOL) verifyPassword: (NSString *)password;
- (void) lock;
- (void) changePassword: (NSString *)password;

/* Raises KCKeyringErrorLocked (as an exception) when locked: callers must
 * check -isLocked first, reading a locked keyring is a programming error. */
- (NSData *) fileData;

/* Empty while locked. */
- (NSArray *) items;
- (KCItem *) itemWithIdentifier: (NSString *)identifier;
/* Identifiers of all items, known even while locked (from the index). */
- (NSArray *) itemIdentifiers;
/* Works locked (hashed index) and unlocked (plain attributes). */
- (NSArray *) itemIdentifiersMatchingAttributes: (NSDictionary *)query;

/* replace: an existing item with exactly the same attributes is updated in
 * place instead of adding a second one, as the specification describes. */
- (KCItem *) createItemWithLabel: (NSString *)label
                      attributes: (NSDictionary *)attributes
                          secret: (NSData *)secret
                     contentType: (NSString *)contentType
                         replace: (BOOL)replace;
- (void) deleteItem: (KCItem *)item;
/* Call after changing an item's label, attributes or secret. */
- (void) itemDidChange: (KCItem *)item;

@end
