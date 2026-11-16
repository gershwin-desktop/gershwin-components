/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Keyrings on disk across "sessions": what one instance writes, a fresh
 * instance (the next login) must find, locked, under the same alias. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "KCKeyring.h"
#import "KCCollection.h"
#import "KCItem.h"
#import "KCTestSupport.h"
#include <sys/stat.h>

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *dir = KCTemporaryDirectory(@"keyring");
  NSError *error = nil;

  START_SET("create, alias, save, reload")
  {
    KCKeyring *k = [[[KCKeyring alloc] initWithDirectory: dir] autorelease];
    KCCollection *login;
    KCCollection *second;

    PASS([k load: &error] && [[k collections] count] == 0, "empty directory loads");
    login = [k createCollectionWithLabel: @"Login" password: @"pw" error: &error];
    PASS_EQUAL([login name], @"login", "name derived from the label");
    second = [k createCollectionWithLabel: @"Login" password: @"pw" error: &error];
    PASS(second != nil && ![[second name] isEqual: @"login"],
      "a second keyring with the same label gets a unique name");
    PASS([k collectionForAlias: @"default"] == nil, "no default alias yet");
    PASS([k setAlias: @"default" forCollection: login error: &error], "alias set");
    PASS_EQUAL([k collectionForAlias: @"default"], login, "alias resolves");
    PASS_EQUAL([k aliasForCollection: login], @"default", "reverse alias");

    [login createItemWithLabel: @"token"
      attributes: [NSDictionary dictionaryWithObject: @"cli" forKey: @"service"]
      secret: KCUTF8(@"abc") contentType: @"text/plain" replace: YES];
    PASS([k saveCollection: login error: &error], "saved");

    struct stat st;
    NSString *file = [dir stringByAppendingPathComponent: @"login.keyring"];
    PASS(stat([file fileSystemRepresentation], &st) == 0
      && (st.st_mode & 0777) == 0600, "keyring file is private (0600)");

    KCKeyring *next = [[[KCKeyring alloc] initWithDirectory: dir] autorelease];
    PASS([next load: &error], "a fresh instance loads");
    PASS([[next collections] count] == 2, "both keyrings found");
    KCCollection *again = [next collectionForAlias: @"default"];
    PASS_EQUAL([again name], @"login", "alias survives");
    PASS([again isLocked], "keyrings start locked in a new session");
    PASS([again unlockWithPassword: @"pw" error: &error]
      && [[[again items] lastObject] secret] != nil
      && [[[[again items] lastObject] secret] isEqual: KCUTF8(@"abc")],
      "the item written earlier is there after unlock");

    PASS([next deleteCollection: again error: &error], "delete");
    PASS(![[NSFileManager defaultManager] fileExistsAtPath: file],
      "file removed");
    PASS([next collectionForAlias: @"default"] == nil, "alias removed with it");

    KCKeyring *third = [[[KCKeyring alloc] initWithDirectory: dir] autorelease];
    PASS([third load: &error] && [[third collections] count] == 1
      && [third collectionForAlias: @"default"] == nil,
      "deletion and alias removal persisted");
  }
  END_SET("create, alias, save, reload")

  START_SET("unreadable keyring fails loading")
  {
    NSString *bad = [dir stringByAppendingPathComponent: @"broken.keyring"];
    KCKeyring *k = [[[KCKeyring alloc] initWithDirectory: dir] autorelease];
    [KCUTF8(@"garbage") writeToFile: bad atomically: YES];
    PASS(![k load: &error] && error != nil, "a corrupt file is an error, not skipped");
  }
  END_SET("unreadable keyring fails loading")

  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  [arp release];
  return 0;
}
