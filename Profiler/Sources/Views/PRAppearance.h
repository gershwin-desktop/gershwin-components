/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

@class PRSymbol;

/* Colours and number formats shared by the profile views. */
@interface PRAppearance : NSObject

/* Every binary gets its own hue, so one library's frames are recognisable
   anywhere in the graph. Kernel and unresolved frames are kept grey so
   they never look like application code. */
+ (NSColor *)colorForSymbol:(PRSymbol *)symbol highlighted:(BOOL)highlighted;
+ (NSColor *)dimmedColorForSymbol:(PRSymbol *)symbol;

/* The same colours again, addressed by what they stand for, so a legend can
   name them without holding a symbol of its own. */
+ (NSColor *)colorForModuleName:(NSString *)moduleName;
+ (NSColor *)kernelColor;
+ (NSColor *)unknownColor;
+ (NSColor *)dimmedColor;

/* "1.4 s", "12.0 MB", "3,412 allocations" - whatever the unit means. */
+ (NSString *)stringForWeight:(double)weight
                         unit:(PRCostUnit)unit
                    frequency:(NSUInteger)frequency;
+ (NSString *)percentOf:(double)weight total:(double)total;
+ (NSString *)nameOfUnit:(PRCostUnit)unit;

@end
