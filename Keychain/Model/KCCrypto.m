/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCCrypto.h"

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

static void KCCryptoFail(const char *what)
{
  [NSException raise: NSInternalInconsistencyException
              format: @"libcrypto failed in %s", what];
}

/* One cipher pass for both directions. Returns nil only when decryption
 * rejects its input (bad padding or tag); other failures raise. */
static NSData *KCCipher(const EVP_CIPHER *cipher, BOOL encrypt,
                        NSData *input, NSData *key, NSData *iv,
                        NSData *aad, NSData *tagIn, NSData **tagOut)
{
  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  BOOL gcm = (tagIn != nil || tagOut != NULL);
  NSMutableData *out;
  int len = 0;
  int total = 0;
  int ok;

  if (ctx == NULL)
    KCCryptoFail("EVP_CIPHER_CTX_new");
  if ((NSUInteger)EVP_CIPHER_key_length(cipher) != [key length])
    {
      EVP_CIPHER_CTX_free(ctx);
      [NSException raise: NSInvalidArgumentException
                  format: @"wrong key length %lu", (unsigned long)[key length]];
    }

  if (EVP_CipherInit_ex(ctx, cipher, NULL, NULL, NULL, encrypt ? 1 : 0) != 1)
    KCCryptoFail("EVP_CipherInit_ex");
  if (gcm && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN,
                                 (int)[iv length], NULL) != 1)
    KCCryptoFail("EVP_CTRL_GCM_SET_IVLEN");
  if (!gcm && [iv length] != (NSUInteger)EVP_CIPHER_iv_length(cipher))
    {
      EVP_CIPHER_CTX_free(ctx);
      return nil;
    }
  if (EVP_CipherInit_ex(ctx, NULL, NULL, [key bytes], [iv bytes],
                        encrypt ? 1 : 0) != 1)
    KCCryptoFail("EVP_CipherInit_ex key");

  if (aad != nil && [aad length] > 0
    && EVP_CipherUpdate(ctx, NULL, &len, [aad bytes], (int)[aad length]) != 1)
    KCCryptoFail("EVP_CipherUpdate aad");

  out = [NSMutableData dataWithLength: [input length] + 32];
  if (EVP_CipherUpdate(ctx, [out mutableBytes], &len,
                       [input bytes], (int)[input length]) != 1)
    {
      EVP_CIPHER_CTX_free(ctx);
      return nil;
    }
  total = len;

  if (!encrypt && tagIn != nil
    && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)[tagIn length],
                           (void *)[tagIn bytes]) != 1)
    KCCryptoFail("EVP_CTRL_GCM_SET_TAG");

  ok = EVP_CipherFinal_ex(ctx, (unsigned char *)[out mutableBytes] + total, &len);
  if (ok != 1)
    {
      EVP_CIPHER_CTX_free(ctx);
      if (encrypt)
        KCCryptoFail("EVP_CipherFinal_ex");
      return nil;
    }
  total += len;

  if (encrypt && tagOut != NULL)
    {
      NSMutableData *tag = [NSMutableData dataWithLength: 16];
      if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16,
                              [tag mutableBytes]) != 1)
        KCCryptoFail("EVP_CTRL_GCM_GET_TAG");
      *tagOut = tag;
    }

  EVP_CIPHER_CTX_free(ctx);
  [out setLength: total];
  return out;
}

@implementation KCCrypto

+ (NSData *) randomBytes: (NSUInteger)length
{
  NSMutableData *d = [NSMutableData dataWithLength: length];
  if (RAND_bytes([d mutableBytes], (int)length) != 1)
    KCCryptoFail("RAND_bytes");
  return d;
}

+ (NSData *) PBKDF2SHA256WithPassword: (NSString *)password
                                 salt: (NSData *)salt
                           iterations: (unsigned)iterations
                               length: (NSUInteger)length
{
  NSData *pw = [password dataUsingEncoding: NSUTF8StringEncoding];
  NSMutableData *out = [NSMutableData dataWithLength: length];

  if (PKCS5_PBKDF2_HMAC([pw bytes], (int)[pw length],
                        [salt bytes], (int)[salt length], (int)iterations,
                        EVP_sha256(), (int)length, [out mutableBytes]) != 1)
    KCCryptoFail("PKCS5_PBKDF2_HMAC");
  return out;
}

static NSData *KCHMACSHA256(NSData *key, NSData *data)
{
  unsigned char md[EVP_MAX_MD_SIZE];
  unsigned int mdLength = 0;

  if (HMAC(EVP_sha256(), [key bytes], (int)[key length],
           [data bytes], [data length], md, &mdLength) == NULL)
    KCCryptoFail("HMAC");
  return [NSData dataWithBytes: md length: mdLength];
}

/* Written out with HMAC rather than EVP_PKEY_HKDF because LibreSSL only
 * gained the latter recently and the construction is two lines. */
+ (NSData *) HKDFSHA256WithKey: (NSData *)inputKey
                          salt: (NSData *)salt
                          info: (NSData *)info
                        length: (NSUInteger)length
{
  NSData *prk;
  NSMutableData *okm = [NSMutableData data];
  NSData *previous = [NSData data];
  uint8_t counter = 1;

  if (length > 255 * SHA256_DIGEST_LENGTH)
    [NSException raise: NSInvalidArgumentException format: @"HKDF length"];
  if (salt == nil || [salt length] == 0)
    salt = [NSMutableData dataWithLength: SHA256_DIGEST_LENGTH];
  prk = KCHMACSHA256(salt, inputKey);

  while ([okm length] < length)
    {
      NSMutableData *block = [NSMutableData dataWithData: previous];
      if (info != nil)
        [block appendData: info];
      [block appendBytes: &counter length: 1];
      previous = KCHMACSHA256(prk, block);
      [okm appendData: previous];
      counter++;
    }
  [okm setLength: length];
  return okm;
}

+ (NSData *) SHA256: (NSData *)data
{
  unsigned char md[SHA256_DIGEST_LENGTH];
  SHA256([data bytes], [data length], md);
  return [NSData dataWithBytes: md length: sizeof(md)];
}

+ (NSData *) AES128CBCEncrypt: (NSData *)plain key: (NSData *)key iv: (NSData *)iv
{
  NSData *out = KCCipher(EVP_aes_128_cbc(), YES, plain, key, iv, nil, nil, NULL);
  if (out == nil)
    [NSException raise: NSInvalidArgumentException format: @"AES-CBC IV length"];
  return out;
}

+ (NSData *) AES128CBCDecrypt: (NSData *)cipher key: (NSData *)key iv: (NSData *)iv
{
  return KCCipher(EVP_aes_128_cbc(), NO, cipher, key, iv, nil, nil, NULL);
}

+ (NSData *) AES256GCMEncrypt: (NSData *)plain
                          key: (NSData *)key
                        nonce: (NSData *)nonce
               additionalData: (NSData *)aad
                          tag: (NSData **)tag
{
  return KCCipher(EVP_aes_256_gcm(), YES, plain, key, nonce, aad, nil, tag);
}

+ (NSData *) AES256GCMDecrypt: (NSData *)cipher
                          key: (NSData *)key
                        nonce: (NSData *)nonce
               additionalData: (NSData *)aad
                          tag: (NSData *)tag
{
  if ([tag length] != 16)
    return nil;
  return KCCipher(EVP_aes_256_gcm(), NO, cipher, key, nonce, aad, tag, NULL);
}

@end
