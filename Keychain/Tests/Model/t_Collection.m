/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Item storage, attribute search in both lock states, and the encrypted
 * file round trip of one keyring. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "KCCollection.h"
#import "KCItem.h"
#import "KCTestSupport.h"

@interface ChangeRecorder : NSObject
{
@public
  NSMutableArray *kinds;
}
@end

@implementation ChangeRecorder
- (id) init
{
  if ((self = [super init]) != nil)
    kinds = [NSMutableArray new];
  return self;
}
- (void) dealloc
{
  [kinds release];
  [super dealloc];
}
- (void) changed: (NSNotification *)n
{
  [kinds addObject: [[n userInfo] objectForKey: KCChangeKindKey]];
}
@end

static NSDictionary *attrs(NSString *service, NSString *account)
{
  return [NSDictionary dictionaryWithObjectsAndKeys:
    service, @"service", account, @"account", nil];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  KCCollection *c = [[KCCollection alloc] initWithName: @"login"
    label: @"Login" password: @"correct horse"];
  ChangeRecorder *rec = [[ChangeRecorder new] autorelease];

  [[NSNotificationCenter defaultCenter] addObserver: rec
    selector: @selector(changed:) name: KCCollectionDidChangeNotification
    object: c];

  START_SET("item CRUD")
  {
    KCItem *a = [c createItemWithLabel: @"Password for alice on example.org"
      attributes: attrs(@"example.org", @"alice") secret: KCUTF8(@"s3cret")
      contentType: @"text/plain" replace: YES];
    KCItem *b = [c createItemWithLabel: @"bob"
      attributes: attrs(@"example.org", @"bob") secret: KCUTF8(@"pw-b")
      contentType: @"text/plain" replace: YES];

    PASS(![c isLocked], "a new keyring is unlocked");
    PASS([[c items] count] == 2, "two items");
    PASS(![[a identifier] isEqual: [b identifier]], "identifiers are unique");
    PASS_EQUAL([c itemWithIdentifier: [a identifier]], a, "lookup by identifier");
    PASS([a created] != nil && [a modified] != nil, "dates are set");

    KCItem *a2 = [c createItemWithLabel: @"alice again"
      attributes: attrs(@"example.org", @"alice") secret: KCUTF8(@"new")
      contentType: @"text/plain" replace: YES];
    PASS(a2 == a && [[c items] count] == 2, "replace updates the matching item");
    PASS_EQUAL([a secret], KCUTF8(@"new"), "replace stores the new secret");
    PASS_EQUAL([a label], @"alice again", "replace stores the new label");

    KCItem *a3 = [c createItemWithLabel: @"dup"
      attributes: attrs(@"example.org", @"alice") secret: KCUTF8(@"x")
      contentType: @"text/plain" replace: NO];
    PASS(a3 != a && [[c items] count] == 3, "no replace adds a second item");

    [c deleteItem: a3];
    PASS([[c items] count] == 2 && [c itemWithIdentifier: [a3 identifier]] == nil,
      "delete removes the item");
    PASS([rec->kinds containsObject: KCChangeItemCreated]
      && [rec->kinds containsObject: KCChangeItemChanged]
      && [rec->kinds containsObject: KCChangeItemDeleted],
      "created, changed and deleted are announced");
  }
  END_SET("item CRUD")

  START_SET("search by attributes")
  {
    NSArray *both = [c itemIdentifiersMatchingAttributes:
      [NSDictionary dictionaryWithObject: @"example.org" forKey: @"service"]];
    NSArray *alice = [c itemIdentifiersMatchingAttributes: attrs(@"example.org", @"alice")];
    NSArray *none = [c itemIdentifiersMatchingAttributes: attrs(@"example.org", @"carol")];
    NSArray *all = [c itemIdentifiersMatchingAttributes: [NSDictionary dictionary]];

    PASS([both count] == 2, "one attribute matches both");
    PASS([alice count] == 1, "two attributes narrow to one");
    PASS([none count] == 0, "no match");
    PASS([all count] == 2, "an empty query matches everything");
  }
  END_SET("search by attributes")

  START_SET("encrypted file round trip and lock state")
  {
    NSData *file;
    NSError *error = nil;
    KCCollection *d;
    NSString *aliceId = [[c itemIdentifiersMatchingAttributes:
      attrs(@"example.org", @"alice")] lastObject];

    [c setKdfIterations: 1000];
    [c changePassword: @"correct horse"];
    file = [c fileData];
    PASS([file length] > 0, "file data is produced");
    PASS([file rangeOfData: KCUTF8(@"alice") options: 0
      range: NSMakeRange(0, [file length])].location == NSNotFound
      && [file rangeOfData: KCUTF8(@"pw-b") options: 0
      range: NSMakeRange(0, [file length])].location == NSNotFound,
      "neither attribute values nor secrets appear in the file");

    d = [KCCollection collectionWithName: @"login" fileData: file error: &error];
    PASS(d != nil && [d isLocked], "reads back locked");
    PASS_EQUAL([d label], @"Login", "label is readable while locked");
    PASS([[d items] count] == 0, "no items visible while locked");
    PASS([[d itemIdentifiers] count] == 2, "identifiers known while locked");
    PASS_EQUAL([d itemIdentifiersMatchingAttributes: attrs(@"example.org", @"alice")],
      [NSArray arrayWithObject: aliceId], "search works on the hashed index while locked");
    PASS([[d itemIdentifiersMatchingAttributes: attrs(@"example.org", @"carol")] count] == 0,
      "locked search does not match other values");

    PASS(![d unlockWithPassword: @"wrong" error: &error]
      && [error code] == KCKeyringErrorWrongPassword, "wrong password refused");
    PASS([d isLocked], "still locked");
    PASS(![d verifyPassword: @"wrong"] && [d verifyPassword: @"correct horse"],
      "verifyPassword tells right from wrong");

    PASS([d unlockWithPassword: @"correct horse" error: &error], "unlocks");
    PASS_EQUAL([[d itemWithIdentifier: aliceId] secret], KCUTF8(@"new"),
      "secret survives the round trip");
    PASS_EQUAL([[d itemWithIdentifier: aliceId] attributes],
      attrs(@"example.org", @"alice"), "attributes survive the round trip");

    [d lock];
    PASS([d isLocked] && [d itemWithIdentifier: aliceId] == nil,
      "lock forgets the decrypted items");
    PASS_EXCEPTION([d fileData], NSInternalInconsistencyException,
      "a locked keyring cannot be written");

    NSMutableDictionary *plist = [NSPropertyListSerialization
      propertyListWithData: file options: NSPropertyListMutableContainers
      format: NULL error: NULL];
    NSMutableData *ct = [[[plist objectForKey: @"Ciphertext"] mutableCopy] autorelease];
    ((uint8_t *)[ct mutableBytes])[0] ^= 0x80;
    [plist setObject: ct forKey: @"Ciphertext"];
    NSData *tampered = [NSPropertyListSerialization dataWithPropertyList: plist
      format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
    KCCollection *t = [KCCollection collectionWithName: @"login"
      fileData: tampered error: &error];
    PASS(t != nil && ![t unlockWithPassword: @"correct horse" error: &error],
      "a modified ciphertext does not unlock");

    [plist setObject: @"something.else" forKey: @"Format"];
    NSData *foreign = [NSPropertyListSerialization dataWithPropertyList: plist
      format: NSPropertyListBinaryFormat_v1_0 options: 0 error: NULL];
    PASS([KCCollection collectionWithName: @"login" fileData: foreign error: &error] == nil
      && [error code] == KCKeyringErrorUnsupportedFormat,
      "a file of another format is refused");
    PASS([KCCollection collectionWithName: @"login" fileData: KCUTF8(@"junk")
      error: &error] == nil && [error code] == KCKeyringErrorCorruptFile,
      "garbage is refused");
  }
  END_SET("encrypted file round trip and lock state")

  START_SET("display columns")
  {
    KCItem *git = [[[KCItem alloc] initWithIdentifier: @"9"] autorelease];
    KCItem *bare = [[[KCItem alloc] initWithIdentifier: @"10"] autorelease];
    [git setAttributes: [NSDictionary dictionaryWithObjectsAndKeys:
      @"https", @"protocol", @"github.com", @"server", @"octo", @"user", nil]];
    [bare setLabel: @"Just a label"];
    [bare setAttributes: [NSDictionary dictionary]];
    PASS_EQUAL([git displayService], @"github.com", "git credential server as service");
    PASS_EQUAL([git displayAccount], @"octo", "git credential user as account");
    PASS_EQUAL([bare displayService], @"Just a label", "label when nothing else");
    PASS_EQUAL([bare displayAccount], @"", "empty account when none");
  }
  END_SET("display columns")

  [[NSNotificationCenter defaultCenter] removeObserver: rec];
  [c release];
  [arp release];
  return 0;
}
