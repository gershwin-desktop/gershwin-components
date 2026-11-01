/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* A small history plot: a caption, the current value as text, and the course
 * of the value over the samples it is given, oldest sample on the left. */
@interface SparklineView : NSView
{
    NSString *_caption;
    NSString *_valueText;
    NSArray *_values;
    double _maximum;
    NSColor *_lineColor;
}

@property (nonatomic, strong) NSString *caption;
@property (nonatomic, strong) NSString *valueText;
/* NSNumbers, oldest first. */
@property (nonatomic, strong) NSArray *values;
/* Top of the scale.  0 scales to the largest sample. */
@property (nonatomic, assign) double maximum;
@property (nonatomic, strong) NSColor *lineColor;

/* The plotted points inside the given rect, oldest first.  Separate from
 * -drawRect: so the mapping can be tested without a screen. */
- (NSArray *)plotPointsInRect:(NSRect)rect;

@end
