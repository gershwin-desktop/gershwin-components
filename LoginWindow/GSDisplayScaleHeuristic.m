/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GSDisplayScaleHeuristic.h"
#include <math.h>

/*
 * Why these numbers (the same questions GNOME mutter, KDE kscreen/KWin,
 * Windows and ChromeOS answer):
 *
 * - Everybody derives the density from the size the display reports (EDID,
 *   RandR mm_width and mm_height) and distrusts it when it is missing or not
 *   plausible. mutter falls back to 1 without a size and below 1200 pixels
 *   of height; kscreen rounds an ideal DPI-based factor to 25% steps and
 *   guesses the viewing distance from the device type; KWin keeps a minimum
 *   number of logical pixels (1080 high) and treats TVs separately.
 *
 * - Reference density: 109 dpi, a 27 inch 2560x1440 monitor, the densest
 *   panel that people run unscaled at a desk and still find comfortable. A
 *   24 inch 1080p monitor (92 dpi) and everything up to about 122 dpi (the
 *   midpoint to the 1.25 step) therefore stay at 1.0. A 27 inch 4K monitor
 *   (163 dpi) is 1.5, which is also what Windows and the default mode of
 *   other desktops give; a 15.6 inch 1080p laptop (141 dpi) is 1.25, as on
 *   Windows laptops; a 24 inch 4K (185 dpi) is 1.75; a 27 inch 5K is 2.0.
 *
 * - Cap by logical size: density alone would give a 13 inch 4K laptop 3.0,
 *   leaving a 1280x720 desktop. A laptop is held closer than a monitor
 *   (kscreen lowers the ideal for built in panels for the same reason), so
 *   the factor is limited to keep at least 1080 logical pixels of height on
 *   panels of 2160 pixels or more, at least half the pixel height below
 *   that, and never fewer than 720 logical pixels. That gives 2.0 for 13 and
 *   15 inch 4K and 2560x1600 panels and keeps small 1366x768 panels at 1.0.
 *
 * - Not believable sizes give 1.0: zero, a diagonal under 9 inches (the EDID
 *   placeholders 160x90 and 160x100 mm that projectors and TVs report are
 *   all about 7 inches) or over 120 inches, and a physical aspect ratio more
 *   than 12% away from the pixel aspect ratio. A wrong guess of 2.0 makes
 *   the desktop unusable, 1.0 is merely small, and the user can change it.
 */
static const double kReferenceDpi = 109.0;
static const double kMillimetersPerInch = 25.4;
static const double kMinDiagonalInches = 9.0;
static const double kMaxDiagonalInches = 120.0;
static const double kAspectTolerance = 0.12;
static const double kAbsoluteMinLogicalHeight = 720.0;
static const double kComfortableLogicalHeight = 1080.0;

@implementation GSDisplayScaleHeuristic

+ (NSArray *)supportedScales
{
    return [NSArray arrayWithObjects:
        [NSNumber numberWithDouble:1.0], [NSNumber numberWithDouble:1.25],
        [NSNumber numberWithDouble:1.5], [NSNumber numberWithDouble:1.75],
        [NSNumber numberWithDouble:2.0], [NSNumber numberWithDouble:2.5],
        [NSNumber numberWithDouble:3.0], nil];
}

+ (double)recommendedScaleForPixelWidth:(NSUInteger)pixelWidth
                            pixelHeight:(NSUInteger)pixelHeight
                      millimeterWidth:(NSUInteger)millimeterWidth
                     millimeterHeight:(NSUInteger)millimeterHeight
{
    if (pixelWidth == 0 || pixelHeight == 0 ||
        millimeterWidth == 0 || millimeterHeight == 0) {
        return 1.0;
    }

    double diagonalInches = sqrt((double)millimeterWidth * millimeterWidth +
                                 (double)millimeterHeight * millimeterHeight)
                            / kMillimetersPerInch;
    if (diagonalInches < kMinDiagonalInches ||
        diagonalInches > kMaxDiagonalInches) {
        return 1.0;
    }

    double pixelAspect = (double)pixelWidth / pixelHeight;
    double physicalAspect = (double)millimeterWidth / millimeterHeight;
    if (fabs(physicalAspect / pixelAspect - 1.0) > kAspectTolerance) {
        return 1.0;
    }

    double diagonalPixels = sqrt((double)pixelWidth * pixelWidth +
                                 (double)pixelHeight * pixelHeight);
    double ideal = diagonalPixels / diagonalInches / kReferenceDpi;

    double minLogicalHeight = pixelHeight / 2.0;
    if (minLogicalHeight > kComfortableLogicalHeight) {
        minLogicalHeight = kComfortableLogicalHeight;
    }
    if (minLogicalHeight < kAbsoluteMinLogicalHeight) {
        minLogicalHeight = kAbsoluteMinLogicalHeight;
    }
    double cap = pixelHeight / minLogicalHeight;

    double best = 1.0;
    double bestDistance = fabs(ideal - 1.0);
    for (NSNumber *step in [self supportedScales]) {
        double candidate = [step doubleValue];
        // The epsilon keeps a cap that is exactly a step (1080 / 540) usable.
        if (candidate > cap + 1e-9) {
            break;
        }
        double distance = fabs(ideal - candidate);
        if (distance < bestDistance) {
            best = candidate;
            bestDistance = distance;
        }
    }
    return best;
}

@end
