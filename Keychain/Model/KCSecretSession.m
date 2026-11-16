/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCSecretSession.h"
#import "KCCrypto.h"

#include <openssl/bn.h>

NSString * const KCAlgorithmPlain = @"plain";
NSString * const KCAlgorithmDH = @"dh-ietf1024-sha256-aes128-cbc-pkcs7";

/* RFC 2409 section 6.2, the Second Oakley Group. */
static const char *KCOakleyGroup2Prime =
  "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
  "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
  "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
  "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
  "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381"
  "FFFFFFFFFFFFFFFF";
static const NSUInteger KCPrimeLength = 128;

static void KCBNFail(const char *what)
{
  [NSException raise: NSInternalInconsistencyException
              format: @"libcrypto BIGNUM failed in %s", what];
}

static NSData *KCBNToPaddedData(const BIGNUM *n)
{
  NSMutableData *d = [NSMutableData dataWithLength: KCPrimeLength];
  int bytes = BN_num_bytes(n);

  if (bytes > (int)KCPrimeLength)
    KCBNFail("BN_num_bytes");
  BN_bn2bin(n, (unsigned char *)[d mutableBytes] + (KCPrimeLength - bytes));
  return d;
}

@implementation KCDHKeyAgreement
{
  NSData *_privateKey;
  NSData *_publicKey;
}

- (instancetype) init
{
  /* 256 bits of exponent give far more than the 80-bit strength of a
   * 1024-bit group, as libsecret's own choice does. */
  return [self initWithPrivateKey: [KCCrypto randomBytes: 32]];
}

- (instancetype) initWithPrivateKey: (NSData *)privateKey
{
  if ((self = [super init]) != nil)
    {
      BN_CTX *ctx = BN_CTX_new();
      BIGNUM *p = NULL;
      BIGNUM *g = BN_new();
      BIGNUM *x = BN_bin2bn([privateKey bytes], (int)[privateKey length], NULL);
      BIGNUM *y = BN_new();

      if (ctx == NULL || g == NULL || x == NULL || y == NULL
        || BN_hex2bn(&p, KCOakleyGroup2Prime) == 0
        || BN_set_word(g, 2) != 1
        || BN_mod_exp(y, g, x, p, ctx) != 1)
        KCBNFail("public key");
      _privateKey = [privateKey copy];
      _publicKey = KCBNToPaddedData(y);
      BN_clear_free(x);
      BN_free(y);
      BN_free(g);
      BN_free(p);
      BN_CTX_free(ctx);
    }
  return self;
}

- (NSData *) publicKey
{
  return _publicKey;
}

- (NSData *) sharedSecretWithPeerPublicKey: (NSData *)peerKey
{
  BN_CTX *ctx;
  BIGNUM *p = NULL;
  BIGNUM *pMinus1;
  BIGNUM *y;
  BIGNUM *x;
  BIGNUM *s;
  NSData *result = nil;

  if ([peerKey length] == 0 || [peerKey length] > KCPrimeLength)
    return nil;

  ctx = BN_CTX_new();
  pMinus1 = BN_new();
  y = BN_bin2bn([peerKey bytes], (int)[peerKey length], NULL);
  x = BN_bin2bn([_privateKey bytes], (int)[_privateKey length], NULL);
  s = BN_new();
  if (ctx == NULL || pMinus1 == NULL || y == NULL || x == NULL || s == NULL
    || BN_hex2bn(&p, KCOakleyGroup2Prime) == 0
    || BN_copy(pMinus1, p) == NULL || BN_sub_word(pMinus1, 1) != 1)
    KCBNFail("shared secret setup");

  /* 1 and p-1 generate trivial subgroups; reject them and anything >= p. */
  if (BN_cmp(y, BN_value_one()) > 0 && BN_cmp(y, pMinus1) < 0)
    {
      if (BN_mod_exp(s, y, x, p, ctx) != 1)
        KCBNFail("BN_mod_exp");
      result = KCBNToPaddedData(s);
    }

  BN_clear_free(s);
  BN_clear_free(x);
  BN_free(y);
  BN_free(pMinus1);
  BN_free(p);
  BN_CTX_free(ctx);
  return result;
}

@end

@implementation KCSecret

+ (instancetype) secretWithSessionPath: (NSString *)path
                            parameters: (NSData *)parameters
                                 value: (NSData *)value
                           contentType: (NSString *)contentType
{
  KCSecret *s = [self new];
  [s setSessionPath: path];
  [s setParameters: parameters];
  [s setValue: value];
  [s setContentType: contentType];
  return s;
}

@end

@implementation KCSecretSession
{
  NSData *_aesKey;
}

@synthesize algorithm = _algorithm;
@synthesize path = _path;
@synthesize output = _output;

+ (instancetype) sessionWithAlgorithm: (NSString *)algorithm
                                input: (NSData *)input
                                 path: (NSString *)path
{
  return [self sessionWithAlgorithm: algorithm input: input path: path
                       keyAgreement: nil];
}

+ (instancetype) sessionWithAlgorithm: (NSString *)algorithm
                                input: (NSData *)input
                                 path: (NSString *)path
                         keyAgreement: (KCDHKeyAgreement *)agreement
{
  KCSecretSession *session = [self new];

  session->_algorithm = [algorithm copy];
  session->_path = [path copy];

  if ([algorithm isEqualToString: KCAlgorithmPlain])
    {
      session->_output = [NSData data];
      return session;
    }
  if ([algorithm isEqualToString: KCAlgorithmDH])
    {
      NSData *shared;

      if (agreement == nil)
        agreement = [KCDHKeyAgreement new];
      shared = [agreement sharedSecretWithPeerPublicKey: input];
      if (shared == nil)
        return nil;
      session->_aesKey = [KCCrypto HKDFSHA256WithKey: shared salt: nil
                                                info: [NSData data] length: 16];
      session->_output = [agreement publicKey];
      return session;
    }
  return nil;
}

- (NSData *) aesKey
{
  return _aesKey;
}

- (KCSecret *) encodePlaintext: (NSData *)plain contentType: (NSString *)type
{
  if (_aesKey == nil)
    return [KCSecret secretWithSessionPath: _path parameters: [NSData data]
                                     value: plain contentType: type];
  NSData *iv = [KCCrypto randomBytes: 16];
  return [KCSecret secretWithSessionPath: _path parameters: iv
    value: [KCCrypto AES128CBCEncrypt: plain key: _aesKey iv: iv]
    contentType: type];
}

- (NSData *) decodeSecret: (KCSecret *)secret
{
  if (![[secret sessionPath] isEqualToString: _path])
    return nil;
  if (_aesKey == nil)
    return [secret value];
  if ([[secret parameters] length] != 16)
    return nil;
  return [KCCrypto AES128CBCDecrypt: [secret value] key: _aesKey
                                 iv: [secret parameters]];
}

@end
