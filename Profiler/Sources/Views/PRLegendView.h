/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* One key of the legend: a colour and what it stands for. An entry without
   a colour is a plain note, for a recording whose colours carry no meaning
   that could be named. */
@interface PRLegendEntry : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSColor *color;

+ (PRLegendEntry *)entryWithLabel:(NSString *)label color:(NSColor *)color;
@end

/* Says what the colours of the flame graph mean. The hues come out of the
   binary a frame belongs to, so the key has to be built from the profile
   that is on screen rather than being fixed. */
@interface PRLegendView : NSView
{
    NSArray *_entries;
    NSUInteger _shownCount;
}

- (void)setEntries:(NSArray *)entries;

@end
