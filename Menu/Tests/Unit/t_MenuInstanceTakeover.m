/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Which process a starting Menu may terminate.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../MenuInstanceTakeover.h"

static NSString *const ownExe = @"/System/Library/CoreServices/Applications/Menu.app/Menu";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* Two Menus of the same user: pid 100 serves another display, pid 300 owned
     the selection on our own display. */
  NSDictionary *processes = @{ @100: ownExe, @300: ownExe, @400: @"/usr/bin/xterm" };
  NSString *(^exe)(pid_t) = ^NSString *(pid_t pid) { return processes[@(pid)]; };

  PASS(MenuPreviousInstanceToTerminate(300, 200, ownExe, exe) == 300,
       "the Menu that owned the selection on our display is terminated");
  PASS(MenuPreviousInstanceToTerminate(0, 200, ownExe, exe) == 0,
       "no selection owner on our display: the Menu on another display is left alone");
  PASS(MenuPreviousInstanceToTerminate(200, 200, ownExe, exe) == 0,
       "we never terminate ourselves");
  PASS(MenuPreviousInstanceToTerminate(400, 200, ownExe, exe) == 0,
       "a process running another program is never signalled");
  PASS(MenuPreviousInstanceToTerminate(500, 200, ownExe, exe) == 0,
       "a process that is gone or unreadable is not signalled");
  PASS(MenuPreviousInstanceToTerminate(300, 200, nil, exe) == 0,
       "without our own executable nothing can be matched");

  NSString *mine = MenuExecutablePathForProcess(getpid());
  PASS(mine != nil && [mine hasSuffix: @"t_MenuInstanceTakeover"],
       "the executable of a live process is found");

  [arp release];
  return 0;
}
