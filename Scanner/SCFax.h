/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCImage;

/*
 * CCITT Group 4 (fax) compression of 1-bit images, the compression made
 * for black and white documents: a text page shrinks to a few dozen KB.
 * Done by libtiff, which every platform we build on ships.
 */

/* Writes a 1-bit image as a G4-compressed TIFF with its resolution */
BOOL SCWriteG4TIFF(SCImage *image, NSString *path, NSError **error);

/* The bare G4 data of a 1-bit image, as PDF embeds it (K=-1, 0 is white) */
NSData *SCG4Data(SCImage *image, NSError **error);
