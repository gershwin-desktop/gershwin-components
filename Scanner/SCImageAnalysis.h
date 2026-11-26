/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCImage;

/*
 * Finds the document on a preview: the bounding box of everything that
 * differs clearly from the scanner lid color seen along the edges. Returned
 * as fractions of the preview, origin top left; NSZeroRect when the bed is
 * empty.
 */
NSRect SCContentRectOfImage(SCImage *image);

/*
 * A gamma table with `count` entries from 0 to `maximum`, built from
 * brightness and contrast in -50..50 and gamma in 0.3..3, like the curve
 * controls of other scanning applications.
 */
NSArray *SCGammaTable(NSUInteger count, double maximum, double brightness,
                      double contrast, double gamma);
