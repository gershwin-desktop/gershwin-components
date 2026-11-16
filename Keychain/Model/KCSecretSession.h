/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

extern NSString * const KCAlgorithmPlain;
extern NSString * const KCAlgorithmDH;

/* Diffie-Hellman over the 1024-bit MODP group of RFC 2409 (group 2),
 * generator 2, which is what the Secret Service specification names
 * "dh-ietf1024". Keys are big-endian byte strings as they travel over D-Bus. */
@interface KCDHKeyAgreement : NSObject

- (instancetype) init;
/* A fixed private key, for known-answer tests. */
- (instancetype) initWithPrivateKey: (NSData *)privateKey;

- (NSData *) publicKey;
/* Returns nil when the peer key is out of range (1 < y < p-1), because a
 * degenerate key would make the session key predictable. The result is
 * left-padded to the 128-byte prime length as libsecret and gnome-keyring
 * do; without the padding one session in 256 would derive a different key. */
- (NSData *) sharedSecretWithPeerPublicKey: (NSData *)peerKey;

@end

/* The (oayays) Secret structure of the specification. */
@interface KCSecret : NSObject

@property (nonatomic, copy) NSString *sessionPath;
@property (nonatomic, copy) NSData *parameters;
@property (nonatomic, copy) NSData *value;
@property (nonatomic, copy) NSString *contentType;

+ (instancetype) secretWithSessionPath: (NSString *)path
                            parameters: (NSData *)parameters
                                 value: (NSData *)value
                           contentType: (NSString *)contentType;

@end

/* One negotiated transport session. It turns stored plaintext into the
 * Secret a client receives and back, and knows nothing about D-Bus. */
@interface KCSecretSession : NSObject

@property (nonatomic, readonly, copy) NSString *algorithm;
@property (nonatomic, readonly, copy) NSString *path;
/* The value OpenSession returns to the client: our public key for DH,
 * nothing for plain. */
@property (nonatomic, readonly, copy) NSData *output;

/* Returns nil for an unsupported algorithm or unusable client input. */
+ (instancetype) sessionWithAlgorithm: (NSString *)algorithm
                                input: (NSData *)input
                                 path: (NSString *)path;
/* For tests: DH with a fixed server private key. */
+ (instancetype) sessionWithAlgorithm: (NSString *)algorithm
                                input: (NSData *)input
                                 path: (NSString *)path
                         keyAgreement: (KCDHKeyAgreement *)agreement;

- (KCSecret *) encodePlaintext: (NSData *)plain contentType: (NSString *)type;
/* Returns nil when the secret does not belong to this session or does not
 * decrypt. */
- (NSData *) decodeSecret: (KCSecret *)secret;

/* The derived AES-128 key (DH only), exposed for tests. */
- (NSData *) aesKey;

@end
