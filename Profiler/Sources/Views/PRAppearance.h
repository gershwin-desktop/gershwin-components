/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

@class PRSymbol;

/* Colours and icons shared by the profile views. The numbers they show
   are put into words by PRFormat, which the command line tool uses too. */
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


/* The icons of the recording controls, drawn instead of loaded so that they
   stay sharp whatever the scale factor is. */
+ (NSImage *)recordIconOfSize:(CGFloat)size;
+ (NSImage *)stopIconOfSize:(CGFloat)size;

@end
