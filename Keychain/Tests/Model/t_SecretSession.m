/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Session negotiation as a libsecret client sees it. The DH vector was
 * computed independently with Python's pow() and hmac (RFC 2409 group 2,
 * HKDF-SHA256 without salt or info, 16 bytes), and its keys are chosen so
 * the shared secret starts with a zero byte: an implementation that forgets
 * to pad derives a different key and fails here. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "KCCrypto.h"
#import "KCSecretSession.h"
#import "KCTestSupport.h"

static NSString * const kClientPublic =
  @"559d9766a85cfde34c6b33c0e4688a0f8b60c38ed5e54b505b990bcbef7bbd42"
  "d823d426bbae152597c942c4307f147fdc5f725cf12e385fa0c05ec774b1ddaf"
  "72ea90e85d7b01abed71a89c9b2693ebcebccf8a4b528310583fb3b047e4644a"
  "2bec563dba7fe7b4b423e9111e7453119fba55146f79eeb345f28094cfb8f26c";
static NSString * const kServerPublic =
  @"457120764f3a1e6fd58103e41a4093a6c8bc1d97cb8759de41c21afdd2d3048a"
  "5ef3d88ce24aa6ba4fe30bcfb0b0f75abf1a8aeaff3723f1bf53740c902005e1"
  "199fabad7c538e94a7034fd585339a02f3634893f748929d2a7257643e398130"
  "541ae64124c17d4507a97f1cbebeb7b933642b8df479eb59e36cfeffbf1671dd";
static NSString * const kShared =
  @"007e7126bcd613bcc54b0a69370d71747277adc87571bc297cffa04e6dbae5a4"
  "56c49312c792ff31fdcb66a4140588323a1d53b545fdaaa71a133cc139412978"
  "933fd10e8ddc749273c37b5c7190c00b8d8f7ecf875c88ddc3ed5c4873f4170e"
  "cdcc89c974e5ddc2262eafe1b414499c89cf81ce2f98976807c3753e9c964309";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSData *serverPrivate = KCDataFromHex(
    @"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");

  START_SET("dh-ietf1024 known answer")
  {
    KCDHKeyAgreement *dh = [[[KCDHKeyAgreement alloc]
      initWithPrivateKey: serverPrivate] autorelease];
    NSData *shared = [dh sharedSecretWithPeerPublicKey:
      KCDataFromHex(kClientPublic)];

    PASS_EQUAL([dh publicKey], KCDataFromHex(kServerPublic),
      "public key is 2^x mod p, 128 bytes big-endian");
    PASS([shared length] == 128, "shared secret padded to 128 bytes");
    PASS_EQUAL(shared, KCDataFromHex(kShared), "shared secret matches");
    PASS([dh sharedSecretWithPeerPublicKey: KCDataFromHex(@"01")] == nil,
      "peer key 1 is rejected");
    PASS([dh sharedSecretWithPeerPublicKey: [NSData data]] == nil,
      "empty peer key is rejected");

    KCDHKeyAgreement *random = [[KCDHKeyAgreement new] autorelease];
    PASS([[random publicKey] length] == 128, "random key pair has a 128 byte public key");
  }
  END_SET("dh-ietf1024 known answer")

  START_SET("dh session")
  {
    KCDHKeyAgreement *dh = [[[KCDHKeyAgreement alloc]
      initWithPrivateKey: serverPrivate] autorelease];
    KCSecretSession *s = [KCSecretSession sessionWithAlgorithm: KCAlgorithmDH
      input: KCDataFromHex(kClientPublic)
      path: @"/org/freedesktop/secrets/session/s1" keyAgreement: dh];
    NSData *key = KCDataFromHex(@"557a164f2c23a2b8e27887065b1be67c");

    PASS(s != nil, "session opens");
    PASS_EQUAL([s output], KCDataFromHex(kServerPublic),
      "OpenSession output is the server public key");
    PASS_EQUAL([s aesKey], key, "AES key is HKDF-SHA256 of the padded secret");

    KCSecret *out = [s encodePlaintext: KCUTF8(@"hunter2")
                           contentType: @"text/plain"];
    PASS_EQUAL([out sessionPath], @"/org/freedesktop/secrets/session/s1",
      "secret names its session");
    PASS([[out parameters] length] == 16, "parameters carry the 16 byte IV");
    PASS_EQUAL([KCCrypto AES128CBCDecrypt: [out value] key: key
                                        iv: [out parameters]],
      KCUTF8(@"hunter2"), "client decrypts with the IV from the parameters");
    PASS_EQUAL([out contentType], @"text/plain", "content type passes through");

    NSData *iv = [KCCrypto randomBytes: 16];
    KCSecret *in = [KCSecret secretWithSessionPath:
      @"/org/freedesktop/secrets/session/s1" parameters: iv
      value: [KCCrypto AES128CBCEncrypt: KCUTF8(@"from client") key: key iv: iv]
      contentType: @"text/plain"];
    PASS_EQUAL([s decodeSecret: in], KCUTF8(@"from client"),
      "decodes what a client encrypted");

    KCSecret *foreign = [KCSecret secretWithSessionPath:
      @"/org/freedesktop/secrets/session/other" parameters: iv
      value: [in value] contentType: @"text/plain"];
    PASS([s decodeSecret: foreign] == nil, "a secret of another session is refused");

    KCSecret *noIV = [KCSecret secretWithSessionPath:
      @"/org/freedesktop/secrets/session/s1" parameters: [NSData data]
      value: [in value] contentType: @"text/plain"];
    PASS([s decodeSecret: noIV] == nil, "a secret without IV is refused");
  }
  END_SET("dh session")

  START_SET("plain session")
  {
    KCSecretSession *s = [KCSecretSession sessionWithAlgorithm: KCAlgorithmPlain
      input: KCUTF8(@"") path: @"/org/freedesktop/secrets/session/s2"];
    KCSecret *out = [s encodePlaintext: KCUTF8(@"pw") contentType: @"text/plain"];

    PASS(s != nil, "plain session opens");
    PASS([[s output] length] == 0, "no output for plain");
    PASS([[out parameters] length] == 0 && [[out value] isEqual: KCUTF8(@"pw")],
      "plain secret travels as is");
    PASS_EQUAL([s decodeSecret: out], KCUTF8(@"pw"), "plain decode");
  }
  END_SET("plain session")

  START_SET("unsupported")
  {
    PASS([KCSecretSession sessionWithAlgorithm: @"dh-ietf2048-foo"
      input: [NSData data] path: @"/s"] == nil, "unknown algorithm refused");
    PASS([KCSecretSession sessionWithAlgorithm: KCAlgorithmDH
      input: KCDataFromHex(@"00") path: @"/s"] == nil,
      "degenerate DH input refused");
  }
  END_SET("unsupported")

  [arp release];
  return 0;
}
