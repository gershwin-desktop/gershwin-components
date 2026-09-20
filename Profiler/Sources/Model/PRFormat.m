/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRFormat.h"

@implementation PRFormat

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

+ (NSString *)percentOf:(double)weight total:(double)total
{
    if (total <= 0)
        return @"-";
    return [NSString stringWithFormat:@"%.1f %%", weight / total * 100.0];
}

@end
