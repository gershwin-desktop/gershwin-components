/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "PRTypes.h"

/* Turns the numbers of a profile into the words a reader understands:
   "1.4 s", "12.0 MB", "3,412 allocations". It knows nothing of the screen,
   so the command line tool says the same as the windows do. */
@interface PRFormat : NSObject

+ (NSString *)stringForBytes:(double)bytes;
+ (NSString *)stringForWeight:(double)weight
                         unit:(PRCostUnit)unit
                    frequency:(NSUInteger)frequency;
+ (NSString *)percentOf:(double)weight total:(double)total;
+ (NSString *)nameOfUnit:(PRCostUnit)unit;

@end
