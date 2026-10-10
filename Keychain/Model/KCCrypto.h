/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Thin wrappers around libcrypto for the primitives the keyring file and the
 * Secret Service transport encryption need. Only interfaces that exist in
 * both OpenSSL and LibreSSL are used, so the app builds on Linux and the BSDs.
 * A failure inside libcrypto itself (not a wrong password or a forged file)
 * raises NSInternalInconsistencyException: there is no sane way to go on. */
@interface KCCrypto : NSObject

+ (NSData *) randomBytes: (NSUInteger)length;

+ (NSData *) PBKDF2SHA256WithPassword: (NSString *)password
                                 salt: (NSData *)salt
                           iterations: (unsigned)iterations
                               length: (NSUInteger)length;

/* RFC 5869. A nil salt means "no salt" (HashLen zero bytes). */
+ (NSData *) HKDFSHA256WithKey: (NSData *)inputKey
                          salt: (NSData *)salt
                          info: (NSData *)info
                        length: (NSUInteger)length;

+ (NSData *) SHA256: (NSData *)data;

/* AES-128-CBC with PKCS#7 padding, as the Secret Service
 * dh-ietf1024-sha256-aes128-cbc-pkcs7 algorithm mandates. Decryption returns
 * nil when the padding is invalid (wrong key or garbage from a client). */
+ (NSData *) AES128CBCEncrypt: (NSData *)plain key: (NSData *)key iv: (NSData *)iv;
+ (NSData *) AES128CBCDecrypt: (NSData *)cipher key: (NSData *)key iv: (NSData *)iv;

/* AES-256-GCM for the keyring file. Decryption returns nil when the tag
 * does not verify (wrong password or a modified file). */
+ (NSData *) AES256GCMEncrypt: (NSData *)plain
                          key: (NSData *)key
                        nonce: (NSData *)nonce
               additionalData: (NSData *)aad
                          tag: (NSData **)tag;
+ (NSData *) AES256GCMDecrypt: (NSData *)cipher
                          key: (NSData *)key
                        nonce: (NSData *)nonce
               additionalData: (NSData *)aad
                          tag: (NSData *)tag;

@end
