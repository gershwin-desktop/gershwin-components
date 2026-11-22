/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * A scanned raster in memory. Foundation-only so the scanning core can be
 * tested without a display; AppKit code turns it into an NSBitmapImageRep.
 * Pixels are interleaved, 16-bit samples are in host byte order (that is
 * how SANE delivers them). 1-bit images are black and white with 1 for
 * black, as in SANE and fax; their rows are padded to whole bytes. Other
 * rows are tightly packed.
 */
@interface SCImage : NSObject

@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) NSUInteger samplesPerPixel; /* 1 or 3 */
@property (nonatomic, readonly) NSUInteger bitsPerSample;   /* 1, 8 or 16 */
@property (nonatomic, readonly) NSData *pixels;
@property (nonatomic, readonly) double resolution;          /* dpi, 0 if unknown */

- (instancetype) initWithWidth: (NSUInteger)width
                        height: (NSUInteger)height
               samplesPerPixel: (NSUInteger)spp
                 bitsPerSample: (NSUInteger)bps
                        pixels: (NSData *)pixels
                    resolution: (double)dpi;

- (NSUInteger) bytesPerRow;
- (SCImage *) imageWithResolution: (double)dpi;
- (SCImage *) invertedImage;
- (SCImage *) eightBitImage;

/* 1-bit image: pixels darker than threshold (0..255) become black */
- (SCImage *) blackAndWhiteImageWithThreshold: (NSUInteger)threshold;

@end
