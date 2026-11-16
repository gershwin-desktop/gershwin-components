/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_AGInstallRegistry.m - the plist registry behind the Installed page.
 * Every path lives in a temporary directory this tool hands out through the
 * designated initializer, so the round trip and the reconcile rule are
 * proven without ever reading or writing the real ~/Library/AppGarden. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGInstallRegistry.h"
#import "AGApp.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];

  NSString *runDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"t_AGInstallRegistry-%d", (int)getpid()]];
  [fm removeItemAtPath:runDir error:NULL];

  /* --- the directory parameter is honored, asserted before any write --- */
  AGInstallRegistry *registry = [[AGInstallRegistry alloc] initWithDirectory:runDir];
  PASS_EQUAL([registry directory], runDir,
             "the registry stays in the directory the test gave it: %s",
             [[registry directory] UTF8String]);
  PASS([[registry installedNames] count] == 0,
       "a directory without a plist starts with an empty registry (got %lu)",
       (unsigned long)[[registry installedNames] count]);

  AGApp *app = [[AGApp alloc] initWithFeedItem:@{
    @"name": @"Foo_Bar",
    @"description": @"A fixture application for the registry test."
  }];
  BOOL nameOK = (app != nil) && [[app displayName] isEqualToString:@"Foo Bar"];
  PASS(nameOK, "the fixture app derives \"Foo Bar\" from \"Foo_Bar\"");
  if (!nameOK)
    {
      [registry release];
      [app release];
      [arp release];
      return 1;
    }

  NSString *file = [runDir stringByAppendingPathComponent:@"Foo Bar.AppImage"];
  BOOL wrote = [@"payload" writeToFile:file
                            atomically:YES
                              encoding:NSUTF8StringEncoding
                                 error:NULL];
  PASS(wrote, "the fixture AppImage file is on disk");

  /* --- one entry round-trips through record and read --- */
  [registry recordApp:app path:file];

  NSArray *names = [registry installedNames];
  PASS([names count] == 1 && [names[0] isEqualToString:@"Foo_Bar"],
       "recordApp: files the app under its feed name (got %lu entries)",
       (unsigned long)[names count]);

  NSDictionary *entry = [registry entryForName:@"Foo_Bar"];
  PASS(entry != nil, "the recorded entry is readable by name");
  PASS_EQUAL([entry objectForKey:@"path"], file,
             "the entry stores the exact path it was given: %s",
             [[entry objectForKey:@"path"] UTF8String]);
  PASS_EQUAL([entry objectForKey:@"displayName"], @"Foo Bar",
             "the entry stores the display name for rows the catalog cannot supply later");
  PASS([[entry objectForKey:@"installedAt"] isKindOfClass:[NSDate class]],
       "the entry carries the install date as a date");

  /* --- what this launch wrote, the next launch reads back --- */
  AGInstallRegistry *relaunched = [[AGInstallRegistry alloc]
      initWithDirectory:runDir];
  NSDictionary *relaunchedEntry = [relaunched entryForName:@"Foo_Bar"];
  PASS(relaunchedEntry != nil,
       "a registry created after the write reads the entry back");
  PASS_EQUAL([relaunchedEntry objectForKey:@"path"], file,
             "the re-read entry kept the path");
  PASS_EQUAL([relaunchedEntry objectForKey:@"displayName"], @"Foo Bar",
             "the re-read entry kept the display name");
  PASS([[relaunchedEntry objectForKey:@"installedAt"] isKindOfClass:[NSDate class]],
       "the re-read entry kept the install date as a date");

  /* --- reconcile keeps an entry whose file is on disk --- */
  [registry reconcile];
  PASS([registry entryForName:@"Foo_Bar"] != nil,
       "reconcile keeps an entry whose file exists");

  /* --- reconcile drops an entry whose file is gone, and writes the drop --- */
  [fm removeItemAtPath:file error:NULL];
  [registry reconcile];
  PASS([registry entryForName:@"Foo_Bar"] == nil,
       "drops an entry whose file does not exist on reconcile");
  PASS([[registry installedNames] count] == 0,
       "the dropped entry leaves installedNames empty (got %lu)",
       (unsigned long)[[registry installedNames] count]);
  AGInstallRegistry *afterDrop = [[AGInstallRegistry alloc]
      initWithDirectory:runDir];
  PASS([afterDrop entryForName:@"Foo_Bar"] == nil,
       "the reconcile wrote the drop to the plist, not just to memory");

  /* --- removeEntryForName: is a write too --- */
  [registry recordApp:app path:file];
  PASS([[registry installedNames] count] == 1,
       "an entry can be recorded again after it was dropped");
  [registry removeEntryForName:@"Foo_Bar"];
  PASS([registry entryForName:@"Foo_Bar"] == nil,
       "removeEntryForName: drops the entry");
  AGInstallRegistry *afterRemove = [[AGInstallRegistry alloc]
      initWithDirectory:runDir];
  PASS([afterRemove entryForName:@"Foo_Bar"] == nil,
       "removeEntryForName: wrote the removal to the plist");

  /* --- teardown --- */
  [registry release];
  [relaunched release];
  [afterDrop release];
  [afterRemove release];
  [app release];
  [fm removeItemAtPath:runDir error:NULL];
  [arp release];
  return 0;
}
