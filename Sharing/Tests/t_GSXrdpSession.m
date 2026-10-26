/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../GSXrdpSession.m"

static NSString *readFile(NSString *p)
{
  return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"xrdptest-%d", (int)getpid()]];
  NSString *script = [home stringByAppendingPathComponent:@"Gershwin.sh"];
  NSString *wm = [home stringByAppendingPathComponent:@"startwm.sh"];
  NSString *bak = [home stringByAppendingPathComponent:@"startwm.sh.gershwin-backup"];
  NSError *err = nil;

  [fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
  [@"#!/bin/sh\n" writeToFile:script atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  [fm setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0755]
                                                forKey:NSFilePosixPermissions]
       ofItemAtPath:script error:NULL];

  PASS((![GSXrdpSession isConfiguredInHome:home]), "fresh home is not configured");

  /* missing session script: refuse, write nothing */
  err = nil;
  PASS((![GSXrdpSession configureInHome:home
                         sessionScript:[home stringByAppendingPathComponent:@"nope.sh"]
                                 error:&err] && err != nil),
       "refuses when the session script is missing");
  PASS((![fm fileExistsAtPath:wm]), "nothing written on refusal");

  /* configure on a clean home */
  PASS(([GSXrdpSession configureInHome:home sessionScript:script error:&err]),
       "configure on a clean home succeeds");
  PASS(([GSXrdpSession isConfiguredInHome:home]), "configured afterwards");
  PASS(([readFile(wm) rangeOfString:[NSString stringWithFormat:@"exec '%@'", script]].location != NSNotFound),
       "wrapper execs the session script");
  PASS(([fm isExecutableFileAtPath:wm]), "wrapper is executable");
  PASS((![fm fileExistsAtPath:bak]), "no backup when there was nothing before");

  /* idempotent */
  NSString *first = readFile(wm);
  PASS(([GSXrdpSession configureInHome:home sessionScript:script error:&err]
       && [readFile(wm) isEqualToString:first]), "configure twice is a no-op");

  /* restore removes our file */
  PASS(([GSXrdpSession restoreInHome:home error:&err]), "restore succeeds");
  PASS((![fm fileExistsAtPath:wm] && ![GSXrdpSession isConfiguredInHome:home]),
       "wrapper removed");
  PASS(([GSXrdpSession restoreInHome:home error:&err]), "restore twice is a no-op");

  /* foreign startwm.sh: backed up, then restored */
  [@"#!/bin/sh\nexec mine\n" writeToFile:wm atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  PASS((![GSXrdpSession isConfiguredInHome:home]), "foreign file is not ours");
  PASS(([GSXrdpSession configureInHome:home sessionScript:script error:&err]),
       "configure over a foreign file succeeds");
  PASS(([GSXrdpSession isConfiguredInHome:home]), "ours now");
  PASS(([readFile(bak) isEqualToString:@"#!/bin/sh\nexec mine\n"]), "foreign file backed up");
  PASS(([GSXrdpSession configureInHome:home sessionScript:script error:&err]
       && [readFile(bak) isEqualToString:@"#!/bin/sh\nexec mine\n"]),
       "second configure keeps the original backup");
  PASS(([GSXrdpSession restoreInHome:home error:&err]
       && [readFile(wm) isEqualToString:@"#!/bin/sh\nexec mine\n"]
       && ![fm fileExistsAtPath:bak]), "restore brings the foreign file back");

  /* foreign file plus an existing backup: unexpected layout, refuse */
  [@"other\n" writeToFile:bak atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  err = nil;
  PASS((![GSXrdpSession configureInHome:home sessionScript:script error:&err] && err != nil),
       "refuses when a foreign file and a backup both exist");
  PASS(([readFile(wm) isEqualToString:@"#!/bin/sh\nexec mine\n"]
       && [readFile(bak) isEqualToString:@"other\n"]), "both left untouched");

  /* restore never deletes a file that is not ours */
  [fm removeItemAtPath:bak error:NULL];
  err = nil;
  PASS((![GSXrdpSession restoreInHome:home error:&err] && err != nil
       && [fm fileExistsAtPath:wm]), "restore refuses to touch a foreign file");

  [fm removeItemAtPath:home error:NULL];
  [arp release];
  return 0;
}
