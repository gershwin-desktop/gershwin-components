/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "RecordingFrameGeometry.h"

int
main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect screen = NSMakeRect(0, 0, 1280, 800);
  NSRect r;

  START_SET("resize")
    r = RecordingSnapResize(NSMakeRect(9, 100, 300, 200), RecordingSideLeft, screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(0, 100, 309, 200)),
         "a left side dragged near the border goes onto it, the right side stays");
    r = RecordingSnapResize(NSMakeRect(100, 100, 300, 691), RecordingSideTop, screen, 12);
    PASS(NSMaxY(r) == 800 && NSMinY(r) == 100, "the top side reaches the top border");
    r = RecordingSnapResize(NSMakeRect(100, 100, 1172, 200), RecordingSideRight, screen, 12);
    PASS(NSMaxX(r) == 1280 && NSMinX(r) == 100, "the right side reaches the right border");
    r = RecordingSnapResize(NSMakeRect(100, 5, 300, 200), RecordingSideBottom | RecordingSideLeft, screen, 12);
    PASS(NSMinY(r) == 0 && NSMaxY(r) == 205 && NSMinX(r) == 100,
         "only the sides being moved snap");
    r = RecordingSnapResize(NSMakeRect(30, 100, 300, 200), RecordingSideLeft, screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(30, 100, 300, 200)), "a side further away stays where it is");
  END_SET("resize")

  START_SET("move")
    r = RecordingSnapMove(NSMakeRect(7, 100, 300, 200), screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(0, 100, 300, 200)), "moved onto the left border, same size");
    r = RecordingSnapMove(NSMakeRect(100, 595, 300, 200), screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(100, 600, 300, 200)), "moved onto the top border");
    r = RecordingSnapMove(NSMakeRect(5, 3, 300, 200), screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(0, 0, 300, 200)), "into a corner");
    r = RecordingSnapMove(NSMakeRect(50, 50, 300, 200), screen, 12);
    PASS(NSEqualRects(r, NSMakeRect(50, 50, 300, 200)), "away from the borders nothing moves");
  END_SET("move")

  START_SET("sides on the border")
    PASS(RecordingSidesOnScreenBorder(NSMakeRect(0, 0, 1280, 800), screen)
         == (RecordingSideLeft | RecordingSideRight | RecordingSideBottom | RecordingSideTop),
         "the whole screen touches every border");
    PASS(RecordingSidesOnScreenBorder(NSMakeRect(0, 100, 300, 700), screen)
         == (RecordingSideLeft | RecordingSideTop), "left and top");
    PASS(RecordingSidesOnScreenBorder(NSMakeRect(1, 100, 300, 200), screen) == 0, "none");
  END_SET("sides on the border")

  [arp release];
  return 0;
}
