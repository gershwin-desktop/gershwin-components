/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PermissionCheck - finding USB scanners in udev data, group advice. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCPermissionCheck.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_PermissionCheck-%d", getpid()]];
  NSArray *nodes, *session;
  NSString *advice;

  [fm removeItemAtPath: dir error: NULL];
  [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                 attributes: nil error: NULL];
  /* A mouse, a scanner on bus 2 device 4, and a non-USB device */
  [@"E:ID_INPUT_MOUSE=1\n" writeToFile: [dir stringByAppendingPathComponent: @"c189:0"]
                            atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  [@"I:123\nE:libsane_matched=yes\nG:uaccess\n"
    writeToFile: [dir stringByAppendingPathComponent: @"c189:131"]
     atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  [@"E:libsane_matched=yes\n" writeToFile: [dir stringByAppendingPathComponent: @"c21:3"]
                               atomically: NO encoding: NSUTF8StringEncoding error: NULL];

  nodes = [SCPermissionCheck linuxScannerNodesInUdevData: dir devRoot: @"/dev"];
  PASS([nodes count] == 1, "only USB devices udev marked for SANE count");
  PASS_EQUAL([nodes lastObject], @"/dev/bus/usb/002/004",
             "the udev minor number gives bus and device of the node");

  session = [NSArray arrayWithObjects: @"admin", @"scanner", nil];
  PASS([SCPermissionCheck adviceForGroup: @"scanner" userName: @"admin"
                           inSessionGIDs: session inGroupDatabase: YES] == nil,
       "no advice when the session has the group");

  session = [NSArray arrayWithObjects: @"admin", nil];
  advice = [SCPermissionCheck adviceForGroup: @"scanner" userName: @"admin"
                               inSessionGIDs: session inGroupDatabase: NO];
  PASS([advice rangeOfString: @"sudo usermod -aG scanner admin"].location != NSNotFound,
       "a missing membership comes with the command that adds it");

  advice = [SCPermissionCheck adviceForGroup: @"scanner" userName: @"admin"
                               inSessionGIDs: session inGroupDatabase: YES];
  PASS([advice rangeOfString: @"Log out and log in again"].location != NSNotFound
       && [advice rangeOfString: @"usermod"].location == NSNotFound,
       "added but not logged in again: only asks to log in again");

  [fm removeItemAtPath: dir error: NULL];
  [arp release];
  return 0;
}
