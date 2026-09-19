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
#define F(x) ((int32_t)lround((x) * 65536.0))
    NSData *path = PlayerBottomCurveShapePath(8, 10);
    const int32_t *v = [path bytes];
    PASS([path length] == 56 * sizeof(int32_t), "one outline, 56 values");
    PASS(v[0] == 1, "in the first version of the format");
    PASS(v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && v[5] == 0,
         "starting at the top left corner");
    PASS(v[6] == 1 && v[7] == F(1) && v[9] == 0,
         "along the top to the top right corner");
    PASS(v[11] == 1 && v[12] == F(1) && v[14] == F(1) && v[15] == F(-18),
         "down the right side to where the rounded corner starts");
    PASS(v[16] == 2 && v[25] == F(1) && v[26] == F(-10) && v[27] == F(1) && v[28] == F(-8),
         "a quarter circle of 10 pixels into the bottom edge, 8 pixels up");
    PASS(v[29] == 2 && v[30] == F(2.0 / 3) && v[31] == F(-10.0 / 3)
         && v[32] == F(1) && v[33] == F(8.0 / 3),
         "the bottom curves down, so it touches the bottom in the middle");
    PASS(v[38] == 0 && v[39] == F(10) && v[40] == F(1) && v[41] == F(-8),
         "to where the left corner starts");
    PASS(v[42] == 2 && v[51] == 0 && v[52] == 0 && v[53] == F(1) && v[54] == F(-18),
         "a quarter circle up to the left side");
    PASS(v[55] == 3, "and closed");
  END_SET("window with a curved bottom")

  [arp release];
  return 0;
}
