/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRAppearance.h"
#import "PRSymbol.h"

@implementation PRAppearance

+ (double)hueForString:(NSString *)string
{
    unsigned long hash = 5381;
    const char *bytes = [string UTF8String];
    if (bytes == NULL)
        return 0.0;
    while (*bytes)
        hash = ((hash << 5) + hash) + (unsigned char)(*bytes++);
    return (double)(hash % 1000) / 1000.0;
}

+ (NSColor *)colorForModuleName:(NSString *)moduleName
{
    return [self colorForModuleName:moduleName highlighted:NO];
}

+ (NSColor *)colorForModuleName:(NSString *)moduleName
                    highlighted:(BOOL)highlighted
{
    return [NSColor colorWithCalibratedHue:[self hueForString:moduleName]
                                saturation:highlighted ? 0.62 : 0.42
                                brightness:highlighted ? 0.86 : 0.95
                                     alpha:1.0];
}

+ (NSColor *)kernelColor
{
    return [self kernelColorHighlighted:NO];
}

+ (NSColor *)kernelColorHighlighted:(BOOL)highlighted
{
    return [NSColor colorWithCalibratedHue:0.58
                                saturation:0.16
                                brightness:highlighted ? 0.78 : 0.88
                                     alpha:1.0];
}

+ (NSColor *)unknownColor
{
    return [self unknownColorHighlighted:NO];
}

+ (NSColor *)unknownColorHighlighted:(BOOL)highlighted
{
    return [NSColor colorWithCalibratedWhite:highlighted ? 0.72 : 0.82
                                       alpha:1.0];
}

+ (NSColor *)dimmedColor
{
    return [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
}

+ (NSColor *)colorForSymbol:(PRSymbol *)symbol highlighted:(BOOL)highlighted
{
    if (symbol == nil)
        return [NSColor colorWithCalibratedWhite:0.75 alpha:1.0];

    if ([symbol isUnknown])
        return [self unknownColorHighlighted:highlighted];
    if ([symbol isKernel])
        return [self kernelColorHighlighted:highlighted];

    /* The binary decides the colour, so one library's frames are easy to
       follow; a file of folded stacks names none, and then the function
       itself has to provide the variety. */
    NSString *key = [[symbol moduleName] isEqualToString:@"[unknown]"] ?
        [symbol displayName] : [symbol moduleName];
    return [self colorForModuleName:key highlighted:highlighted];
}

+ (NSColor *)dimmedColorForSymbol:(PRSymbol *)symbol
{
    (void)symbol;
    return [self dimmedColor];
}

+ (NSString *)nameOfUnit:(PRCostUnit)unit
{
    switch (unit) {
        case PRCostUnitBytes: return @"bytes";
        case PRCostUnitAllocations: return @"allocations";
        case PRCostUnitSamples:
        default: return @"samples";
    }
}

+ (NSString *)stringForBytes:(double)bytes
{
    if (bytes >= 1024.0 * 1024.0 * 1024.0)
        return [NSString stringWithFormat:@"%.2f GB", bytes / 1073741824.0];
    if (bytes >= 1024.0 * 1024.0)
        return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0];
    if (bytes >= 1024.0)
        return [NSString stringWithFormat:@"%.1f kB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.0f B", bytes];
}

+ (NSString *)stringForWeight:(double)weight
                         unit:(PRCostUnit)unit
                    frequency:(NSUInteger)frequency
{
    switch (unit) {
        case PRCostUnitBytes:
            return [self stringForBytes:weight];
        case PRCostUnitAllocations:
            return [NSString stringWithFormat:@"%.0f", weight];
        case PRCostUnitSamples:
        default:
            break;
    }

    /* A sample stands for one period of the sampling timer, so the sample
       count is the CPU time the program spent there. */
    if (frequency > 0) {
        double seconds = weight / (double)frequency;
        if (seconds >= 1.0)
            return [NSString stringWithFormat:@"%.2f s", seconds];
        return [NSString stringWithFormat:@"%.0f ms", seconds * 1000.0];
    }
    return [NSString stringWithFormat:@"%.0f", weight];
}

+ (void)drawRecordIcon:(NSCustomImageRep *)rep
{
    NSRect bounds = NSMakeRect(0, 0, [rep size].width, [rep size].height);
    [[NSColor colorWithCalibratedRed:0.78 green:0.15 blue:0.15 alpha:1.0] set];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(bounds, 1.0, 1.0)] fill];
}

+ (void)drawStopIcon:(NSCustomImageRep *)rep
{
    NSRect bounds = NSMakeRect(0, 0, [rep size].width, [rep size].height);
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1.0] set];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(bounds, 2.0, 2.0)] fill];
}

+ (NSImage *)iconOfSize:(CGFloat)size drawnWith:(SEL)selector
{
    NSSize square = NSMakeSize(size, size);
    NSCustomImageRep *rep = [[NSCustomImageRep alloc]
                             initWithDrawSelector:selector delegate:self];
    [rep setSize:square];

    NSImage *image = [[NSImage alloc] initWithSize:square];
    [image addRepresentation:rep];
    return image;
}

+ (NSImage *)recordIconOfSize:(CGFloat)size
{
    return [self iconOfSize:size drawnWith:@selector(drawRecordIcon:)];
}

+ (NSImage *)stopIconOfSize:(CGFloat)size
{
    return [self iconOfSize:size drawnWith:@selector(drawStopIcon:)];
}

+ (NSString *)percentOf:(double)weight total:(double)total
{
    if (total <= 0)
        return @"-";
    return [NSString stringWithFormat:@"%.1f %%", weight / total * 100.0];
}

@end
