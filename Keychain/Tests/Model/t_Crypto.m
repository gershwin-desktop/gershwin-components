/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Known-answer tests for the primitives, so a libcrypto that behaves
 * differently (LibreSSL on the BSDs) shows up here and not as a client that
 * cannot read its password. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "KCCrypto.h"
#import "KCTestSupport.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("PBKDF2-HMAC-SHA256 (RFC 7914 section 11 style vectors)")
  {
    NSData *salt = KCUTF8(@"salt");
    NSData *one = [KCCrypto PBKDF2SHA256WithPassword: @"password" salt: salt
                                          iterations: 1 length: 32];
    NSData *two = [KCCrypto PBKDF2SHA256WithPassword: @"password" salt: salt
                                          iterations: 2 length: 32];
    PASS_EQUAL(one, KCDataFromHex(@"120fb6cffcf8b32c43e7225256c4f837"
      "a86548c92ccc35480805987cb70be17b"), "1 iteration matches");
    PASS_EQUAL(two, KCDataFromHex(@"ae4d0c95af6b46d32d0adff928f06dd0"
      "2a303f8ef3c251dfd6e2d85a95474c43"), "2 iterations match");
  }
  END_SET("PBKDF2-HMAC-SHA256 (RFC 7914 section 11 style vectors)")

  START_SET("HKDF-SHA256 (RFC 5869)")
  {
    NSData *ikm = KCDataFromHex(@"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    NSData *tc1 = [KCCrypto HKDFSHA256WithKey: ikm
      salt: KCDataFromHex(@"000102030405060708090a0b0c")
      info: KCDataFromHex(@"f0f1f2f3f4f5f6f7f8f9") length: 42];
    NSData *tc3 = [KCCrypto HKDFSHA256WithKey: ikm salt: nil
      info: [NSData data] length: 42];
    PASS_EQUAL(tc1, KCDataFromHex(@"3cb25f25faacd57a90434f64d0362f2a"
      "2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
      "test case 1 (salt and info)");
    PASS_EQUAL(tc3, KCDataFromHex(@"8da4e775a563c18f715f802a063c5a31"
      "b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"),
      "test case 3 (no salt, no info) as the Secret Service uses it");
  }
  END_SET("HKDF-SHA256 (RFC 5869)")

  START_SET("AES-128-CBC with PKCS#7 (NIST SP 800-38A F.2.1)")
  {
    NSData *key = KCDataFromHex(@"2b7e151628aed2a6abf7158809cf4f3c");
    NSData *iv = KCDataFromHex(@"000102030405060708090a0b0c0d0e0f");
    NSData *plain = KCDataFromHex(@"6bc1bee22e409f96e93d7e117393172a"
      "ae2d8a571e03ac9c9eb76fac45af8e51");
    NSData *cipher = [KCCrypto AES128CBCEncrypt: plain key: key iv: iv];
    NSData *expected = KCDataFromHex(@"7649abac8119b246cee98e9b12e9197d"
      "5086cb9b507219ee95db113a917678b2");
    PASS([cipher length] == 48, "a full padding block is appended");
    PASS_EQUAL([cipher subdataWithRange: NSMakeRange(0, 32)], expected,
      "ciphertext blocks match the NIST vector");
    PASS_EQUAL([KCCrypto AES128CBCDecrypt: cipher key: key iv: iv], plain,
      "decrypts back and strips the padding");

    NSData *short5 = KCUTF8(@"hello");
    NSData *c5 = [KCCrypto AES128CBCEncrypt: short5 key: key iv: iv];
    PASS([c5 length] == 16, "5 bytes pad to one block");
    PASS_EQUAL([KCCrypto AES128CBCDecrypt: c5 key: key iv: iv], short5,
      "short plaintext round trip");
    PASS([KCCrypto AES128CBCDecrypt: [c5 subdataWithRange: NSMakeRange(0, 15)]
                                key: key iv: iv] == nil,
      "a ciphertext that is not a whole number of blocks is rejected");
  }
  END_SET("AES-128-CBC with PKCS#7 (NIST SP 800-38A F.2.1)")

  START_SET("AES-256-GCM")
  {
    NSData *key = [KCCrypto randomBytes: 32];
    NSData *nonce = [KCCrypto randomBytes: 12];
    NSData *aad = KCUTF8(@"header fields");
    NSData *plain = KCUTF8(@"the archived items of a keyring");
    NSData *tag = nil;
    NSData *cipher = [KCCrypto AES256GCMEncrypt: plain key: key nonce: nonce
                                 additionalData: aad tag: &tag];
    NSMutableData *flipped = [[cipher mutableCopy] autorelease];

    PASS([tag length] == 16, "16 byte tag");
    PASS(![cipher isEqual: plain], "output is not the plaintext");
    PASS_EQUAL([KCCrypto AES256GCMDecrypt: cipher key: key nonce: nonce
                           additionalData: aad tag: tag], plain,
      "round trip");
    ((uint8_t *)[flipped mutableBytes])[3] ^= 0x01;
    PASS([KCCrypto AES256GCMDecrypt: flipped key: key nonce: nonce
                     additionalData: aad tag: tag] == nil,
      "a flipped ciphertext bit fails authentication");
    PASS([KCCrypto AES256GCMDecrypt: cipher key: key nonce: nonce
                     additionalData: KCUTF8(@"other header") tag: tag] == nil,
      "changed additional data fails authentication");
    PASS([KCCrypto AES256GCMDecrypt: cipher key: [KCCrypto randomBytes: 32]
                              nonce: nonce additionalData: aad tag: tag] == nil,
      "a wrong key fails authentication");
  }
  END_SET("AES-256-GCM")

  START_SET("random bytes")
  {
    NSData *a = [KCCrypto randomBytes: 16];
    NSData *b = [KCCrypto randomBytes: 16];
    PASS([a length] == 16 && ![a isEqual: b], "16 fresh bytes each call");
  }
  END_SET("random bytes")

  [arp release];
  return 0;
}
