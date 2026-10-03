/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The wire types libsecret checks strictly: a reply whose signature is off
 * by one character is rejected by the client as a protocol error. Messages
 * are built and parsed without a bus. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "KCDBusMarshal.h"
#import "KCTestSupport.h"

static NSString * const kSessionPath = @"/org/freedesktop/secrets/session/s7";

static DBusMessage *newMessage(void)
{
  DBusMessage *m = dbus_message_new_method_call("org.freedesktop.secrets",
    "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Test");
  return m;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("secret struct (oayays)")
  {
    DBusMessage *m = newMessage();
    NSArray *secret = [NSArray arrayWithObjects:
      [KCDBusObjectPath pathWithString: kSessionPath],
      KCDataFromHex(@"000102"), KCUTF8(@"value"), @"text/plain", nil];
    NSArray *args = [NSArray arrayWithObject: secret];

    KCDBusAppendArguments(m, @"(oayays)", args);
    PASS(strcmp(dbus_message_get_signature(m), "(oayays)") == 0,
      "message signature is (oayays)");

    NSArray *read = KCDBusReadArguments(m);
    NSArray *s = [read objectAtIndex: 0];
    PASS([read count] == 1 && [s count] == 4, "one struct with four members");
    PASS([[s objectAtIndex: 0] isKindOfClass: [KCDBusObjectPath class]]
      && [[[s objectAtIndex: 0] string] isEqual: kSessionPath],
      "session comes back as an object path");
    PASS_EQUAL([s objectAtIndex: 1], KCDataFromHex(@"000102"), "parameters as NSData");
    PASS_EQUAL([s objectAtIndex: 2], KCUTF8(@"value"), "value as NSData");
    PASS_EQUAL([s objectAtIndex: 3], @"text/plain", "content type");
    dbus_message_unref(m);
  }
  END_SET("secret struct (oayays)")

  START_SET("GetSecrets reply a{o(oayays)}")
  {
    DBusMessage *m = newMessage();
    KCDBusObjectPath *item = [KCDBusObjectPath pathWithString:
      @"/org/freedesktop/secrets/collection/login/1"];
    NSArray *secret = [NSArray arrayWithObjects:
      [KCDBusObjectPath pathWithString: kSessionPath],
      [NSData data], KCUTF8(@"pw"), @"text/plain", nil];
    NSDictionary *dict = [NSDictionary dictionaryWithObject: secret forKey: item];

    KCDBusAppendArguments(m, @"a{o(oayays)}", [NSArray arrayWithObject: dict]);
    PASS(strcmp(dbus_message_get_signature(m), "a{o(oayays)}") == 0,
      "signature a{o(oayays)}");
    NSDictionary *back = [KCDBusReadArguments(m) objectAtIndex: 0];
    PASS([back count] == 1
      && [[[back objectForKey: item] objectAtIndex: 2] isEqual: KCUTF8(@"pw")],
      "keyed by object path");
    dbus_message_unref(m);
  }
  END_SET("GetSecrets reply a{o(oayays)}")

  START_SET("properties a{sv}, ao, empty arrays, variants")
  {
    DBusMessage *m = newMessage();
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
      @"example.org", @"service", @"alice", @"account", nil];
    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:
      [KCDBusVariant variantWithSignature: @"s" value: @"Label"],
        @"org.freedesktop.Secret.Item.Label",
      [KCDBusVariant variantWithSignature: @"a{ss}" value: attrs],
        @"org.freedesktop.Secret.Item.Attributes",
      [KCDBusVariant variantWithSignature: @"t"
        value: [NSNumber numberWithUnsignedLongLong: 1700000000ULL]],
        @"org.freedesktop.Secret.Item.Created",
      [KCDBusVariant variantWithSignature: @"b"
        value: [NSNumber numberWithBool: YES]],
        @"org.freedesktop.Secret.Item.Locked", nil];
    NSArray *paths = [NSArray arrayWithObject:
      [KCDBusObjectPath pathWithString: @"/org/freedesktop/secrets/collection/login"]];
    NSArray *args = [NSArray arrayWithObjects: props, paths, [NSArray array],
      [KCDBusVariant variantWithSignature: @"ay" value: KCUTF8(@"key")], nil];

    KCDBusAppendArguments(m, @"a{sv}aoaov", args);
    PASS(strcmp(dbus_message_get_signature(m), "a{sv}aoaov") == 0,
      "signature a{sv}aoaov");

    NSArray *read = KCDBusReadArguments(m);
    NSDictionary *p = [read objectAtIndex: 0];
    KCDBusVariant *v = [p objectForKey: @"org.freedesktop.Secret.Item.Attributes"];
    PASS([v isKindOfClass: [KCDBusVariant class]]
      && [[v signature] isEqual: @"a{ss}"] && [[v value] isEqual: attrs],
      "variant keeps signature and dictionary value");
    KCDBusVariant *t = [p objectForKey: @"org.freedesktop.Secret.Item.Created"];
    PASS([[t value] unsignedLongLongValue] == 1700000000ULL, "uint64 in variant");
    KCDBusVariant *b = [p objectForKey: @"org.freedesktop.Secret.Item.Locked"];
    PASS([[b signature] isEqual: @"b"] && [[b value] boolValue], "boolean in variant");
    PASS([[read objectAtIndex: 1] count] == 1, "ao with one path");
    PASS([[read objectAtIndex: 2] count] == 0, "empty ao");
    KCDBusVariant *ay = [read objectAtIndex: 3];
    PASS([[ay value] isEqual: KCUTF8(@"key")], "ay in variant reads as NSData");
    dbus_message_unref(m);
  }
  END_SET("properties a{sv}, ao, empty arrays, variants")

  START_SET("type mismatch is a programming error")
  {
    DBusMessage *m = newMessage();
    PASS_EXCEPTION(KCDBusAppendArguments(m, @"o",
      [NSArray arrayWithObject: @"not a path object"]),
      NSInvalidArgumentException, "a string for an object path raises");
    PASS_EXCEPTION(KCDBusAppendArguments(m, @"ss",
      [NSArray arrayWithObject: @"one"]),
      NSInvalidArgumentException, "too few values raises");
    dbus_message_unref(m);
  }
  END_SET("type mismatch is a programming error")

  [arp release];
  return 0;
}
