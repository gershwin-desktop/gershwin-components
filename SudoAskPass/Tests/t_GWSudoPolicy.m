/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* A user who is not in sudoers used to get a password prompt that could
 * never succeed.  After the password is known to be right, SudoAskPass asks
 * sudo whether the user may run anything at all; GWSudoPolicyForPassword
 * gives the answer.  Stand-in sudo scripts play sudo here, so the test needs
 * neither root nor a second account.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "GWSudoPolicy.h"

static NSString *dir;

/* A stand-in sudo: records its stdin and SUDO_ASKPASS, then says `message`
   on stderr and exits with `status`. */
static NSString *stub(NSString *name, NSString *message, int status)
{
  NSString *path = [dir stringByAppendingPathComponent: name];
  NSString *script = [NSString stringWithFormat:
    @"#!/bin/sh\ncat > '%@/stdin'\necho \"askpass=${SUDO_ASKPASS-unset} args=$*\" > '%@/env'\n"
    @"printf '%%s\\n' '%@' >&2\nexit %d\n", dir, dir, message, status];
  [script writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: NULL];
  [[NSFileManager defaultManager] setAttributes:
     [NSDictionary dictionaryWithObject: [NSNumber numberWithShort: 0755] forKey: NSFilePosixPermissions]
                                   ofItemAtPath: path error: NULL];
  return path;
}

static NSString *recorded(NSString *file)
{
  return [NSString stringWithContentsOfFile: [dir stringByAppendingPathComponent: file]
                                   encoding: NSUTF8StringEncoding error: NULL];
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  START_SET("GWSudoPolicy");

  dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
           [NSString stringWithFormat: @"t_GWSudoPolicy.%d", getpid()]];
  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  setenv("SUDO_ASKPASS", "/System/Library/Tools/SudoAskPass", 1);

  PASS (GWSudoPolicyForPassword (@"secret", stub (@"allow", @"", 0)) == GWSudoPolicyAllowed,
        "a user sudo lets list privileges may administer");
  PASS_EQUAL (recorded (@"stdin"), @"secret\n", "the password reaches sudo on its stdin");
  NSString *env = recorded (@"env");
  PASS ([env hasPrefix: @"askpass=unset "], "sudo is not told to call this askpass again (%s)", [env UTF8String]);
  PASS ([env rangeOfString: @"-S"].location != NSNotFound && [env rangeOfString: @"-l"].location != NSNotFound,
        "sudo reads the password from stdin and only lists (%s)", [env UTF8String]);

  PASS (GWSudoPolicyForPassword (@"secret", stub (@"refuse", @"Sorry, user tom may not run sudo on host.", 1))
          == GWSudoPolicyRefused,
        "\"may not run sudo\" means the user may not administer");
  PASS (GWSudoPolicyForPassword (@"secret", stub (@"notin", @"tom is not in the sudoers file.", 1))
          == GWSudoPolicyRefused,
        "\"not in the sudoers file\" means the user may not administer");
  PASS (GWSudoPolicyForPassword (@"secret", stub (@"badpw", @"Sorry, try again.", 1)) == GWSudoPolicyUnknown,
        "any other failure is not taken as a refusal");
  PASS (GWSudoPolicyForPassword (@"secret", [dir stringByAppendingPathComponent: @"missing"]) == GWSudoPolicyUnknown,
        "a sudo that cannot be started is not taken as a refusal");

  [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
  END_SET("GWSudoPolicy");
  [pool release];
  return 0;
}
