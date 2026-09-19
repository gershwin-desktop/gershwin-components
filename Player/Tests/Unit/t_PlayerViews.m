/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_PlayerViews.m - labels for titles, artists and station names shorten
 * long text in the middle, so both its start and its end stay readable.
 * NSTextField needs NSApp, so this test needs an X display (DISPLAY). */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "PlayerViews.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  [NSApplication sharedApplication];

  START_SET("labels")
    NSTextField *label = PlayerMakeLabel([NSFont systemFontOfSize: 11]);
    PASS([[label cell] lineBreakMode] == NSLineBreakByTruncatingMiddle,
         "long text is shortened in the middle");
    PASS(![[label cell] wraps], "on a single line");
    PASS(![label isEditable] && ![label isSelectable] && ![label isBezeled]
         && ![label drawsBackground], "it is a plain label");

    PASS([label isKindOfClass: [NSTextField class]] && [label class] == [NSTextField class],
         "a plain NSTextField, so tools see a text field");
  END_SET("labels")

  [arp release];
  return 0;
}
