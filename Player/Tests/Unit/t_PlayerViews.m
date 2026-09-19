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

  START_SET("window with a curved bottom")
    /* _WM_SHAPE_PATH: version, then commands; a point is four 16.16
     * numbers: fraction of the width, pixels, fraction of the height, pixels */
    NSData *path = PlayerBottomCurveShapePath(8);
    const int32_t *v = [path bytes];
    PASS([path length] == 30 * sizeof(int32_t), "one outline, 30 values");
    PASS(v[0] == 1, "in the first version of the format");
    PASS(v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && v[5] == 0,
         "starting at the top left corner");
    PASS(v[6] == 1 && v[7] == 65536 && v[9] == 0,
         "along the top to the top right corner");
    PASS(v[11] == 1 && v[12] == 65536 && v[14] == 65536 && v[15] == -8 * 65536,
         "down the right side to 8 pixels above the bottom");
    PASS(v[16] == 2, "then a curve");
    PASS(v[19] == 65536 && v[20] == (int32_t)lround(8 * 65536 / 3.0),
         "bulging down past the bottom, so it touches the bottom in the middle");
    PASS(v[25] == 0 && v[26] == 0 && v[27] == 65536 && v[28] == -8 * 65536,
         "to 8 pixels above the bottom on the left side");
    PASS(v[29] == 3, "and closed");
  END_SET("window with a curved bottom")

  [arp release];
  return 0;
}
