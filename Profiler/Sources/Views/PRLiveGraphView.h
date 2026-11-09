/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* A small strip chart of the recent readings of one value, drawn so that
   the user can see whether the program is busy before recording it. */
@interface PRLiveGraphView : NSView
{
    NSMutableArray *_values;
    NSString *_caption;
    double _maximum;
}

@property (nonatomic, copy) NSString *caption;
/* Upper end of the scale; 0 lets the graph scale to what it has seen. */
@property (nonatomic, assign) double maximum;

- (void)addValue:(double)value;
- (void)clear;

@end
