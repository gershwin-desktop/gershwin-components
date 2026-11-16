/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Some apps report their window unmapped while it is being created, so the
   watchdog must see it unmapped on two ticks in a row before it clears the
   menu; a destroyed window is cleared at once. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../MenuWindowWatchdog.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  MenuWatchdogState st = {0, 0};

  PASS(!MenuWatchdogShouldClear(&st, 0x10, YES, YES), "mapped window is kept");
  PASS(!MenuWatchdogShouldClear(&st, 0x10, YES, NO),
    "first unmapped tick keeps the menu");
  PASS(MenuWatchdogShouldClear(&st, 0x10, YES, NO),
    "second consecutive unmapped tick clears");

  MenuWatchdogReset(&st);
  MenuWatchdogShouldClear(&st, 0x10, YES, NO);
  PASS(!MenuWatchdogShouldClear(&st, 0x10, YES, YES), "seen mapped again: kept");
  PASS(!MenuWatchdogShouldClear(&st, 0x10, YES, NO),
    "the unmapped count restarted after a mapped tick");

  MenuWatchdogReset(&st);
  MenuWatchdogShouldClear(&st, 0x10, YES, NO);
  PASS(!MenuWatchdogShouldClear(&st, 0x20, YES, NO),
    "another shown window starts its own count");
  PASS(MenuWatchdogShouldClear(&st, 0x20, YES, NO),
    "and clears on its second unmapped tick");

  MenuWatchdogReset(&st);
  PASS(MenuWatchdogShouldClear(&st, 0x10, NO, NO),
    "a destroyed window is cleared at once");

  [arp release];
  return 0;
}
