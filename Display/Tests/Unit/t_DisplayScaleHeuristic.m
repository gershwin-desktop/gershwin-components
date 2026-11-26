/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayScaleHeuristic.h"

static double scale(NSUInteger w, NSUInteger h, NSUInteger mmw, NSUInteger mmh)
{
    return [DisplayScaleHeuristic recommendedScaleForPixelWidth:w
                                                      pixelHeight:h
                                                millimeterWidth:mmw
                                               millimeterHeight:mmh];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* Desktop monitors stay at 1.0. */
    PASS(scale(1920, 1080, 527, 296) == 1.0, "24 inch 1080p is 1.0");
    PASS(scale(2560, 1440, 597, 336) == 1.0, "27 inch 1440p (109 dpi) is 1.0");
    PASS(scale(3440, 1440, 800, 335) == 1.0, "34 inch ultrawide is 1.0");
    PASS(scale(3840, 2160, 1209, 680) == 1.0, "55 inch 4K TV panel is 1.0");

    /* Laptop panels. */
    PASS(scale(3840, 2160, 294, 165) == 2.0, "13.3 inch 4K is 2.0");
    PASS(scale(3840, 2400, 288, 180) == 2.0, "13.4 inch 4K 16:10 is 2.0");
    PASS(scale(2560, 1600, 286, 179) == 2.0, "13.3 inch 2560x1600 is 2.0");
    PASS(scale(2880, 1800, 302, 189) == 2.0, "14 inch 2.8K is 2.0");
    PASS(scale(1920, 1080, 344, 193) == 1.25, "15.6 inch 1080p is 1.25");
    PASS(scale(1366, 768, 256, 144) == 1.0, "11.6 inch 1366x768 stays 1.0");
    PASS(scale(3840, 2160, 344, 194) == 2.0, "15.6 inch 4K is capped at 2.0");

    /* Large high density monitors. */
    PASS(scale(3840, 2160, 597, 336) == 1.5, "27 inch 4K is 1.5");
    PASS(scale(3840, 2160, 527, 296) == 1.75, "24 inch 4K is 1.75");
    PASS(scale(5120, 2880, 597, 336) == 2.0, "27 inch 5K is 2.0");

    /* Missing or unbelievable physical sizes. */
    PASS(scale(3840, 2160, 0, 0) == 1.0, "no size reported is 1.0");
    PASS(scale(3840, 2160, 294, 0) == 1.0, "zero height is 1.0");
    PASS(scale(3840, 2160, 160, 90) == 1.0, "160x90 mm TV placeholder is 1.0");
    PASS(scale(1920, 1080, 160, 90) == 1.0, "160x90 mm projector is 1.0");
    PASS(scale(3840, 2160, 160, 100) == 1.0, "160x100 mm placeholder is 1.0");
    PASS(scale(3840, 2160, 294, 294) == 1.0, "aspect mismatch is 1.0");
    PASS(scale(0, 0, 294, 165) == 1.0, "no pixels is 1.0");
    PASS(scale(3840, 2160, 9000, 5000) == 1.0, "huge size is 1.0");

    /* Result is always one of the offered steps. */
    NSArray *steps = [DisplayScaleHeuristic supportedScales];
    PASS([steps count] == 7, "seven steps");
    PASS_EQUAL([steps objectAtIndex:0], [NSNumber numberWithDouble:1.0],
               "first step is 1.0");
    PASS_EQUAL(NSStringFromClass([DisplayScaleHeuristic class]),
               @"DisplayScaleHeuristic", "class name");
    PASS([steps containsObject:[NSNumber numberWithDouble:
        scale(3200, 1800, 345, 194)]], "result is a supported step");

    [arp release];
    return 0;
}
