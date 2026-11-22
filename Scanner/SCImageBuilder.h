/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sane/sane.h>

@class SCImage;

/*
 * Assembles the frames SANE delivers for one page into an SCImage: single
 * pass gray or RGB, three-pass red/green/blue, depth 1 (gray line art
 * stays 1-bit, color bits become 8-bit samples), 8 or 16 bits. Frames may arrive with
 * an unknown line count (hand scanners, sheet feeders), so rows are counted
 * from the bytes received.
 */
@interface SCImageBuilder : NSObject

- (BOOL) beginFrameWithParameters: (const SANE_Parameters *)params
                            error: (NSError **)error;
- (void) appendBytes: (const void *)bytes length: (NSUInteger)length;
- (void) endFrame;

/* YES after the frame marked last_frame has ended */
- (BOOL) isComplete;

/* Fraction of the current frame received; 0 when the size is unknown */
- (double) frameProgress;

- (SCImage *) imageWithResolution: (double)dpi error: (NSError **)error;

@end

extern NSString * const SCScannerErrorDomain;
