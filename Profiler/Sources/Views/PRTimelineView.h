/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

@class PRTimelineView;

@protocol PRTimelineViewDelegate <NSObject>
@optional
/* An empty range (start == end) means the whole recording again. */
- (void)timelineView:(PRTimelineView *)view didSelectRange:(PRTimeRange)range;
@end

/* Shows how the cost was spread over the recording and lets the user drag
   out the interesting stretch, so a hang or a redraw storm can be looked at
   on its own instead of being averaged away. */
@interface PRTimelineView : NSView
{
    NSArray *_values;
    NSArray *_curve;
    double _startTime;
    double _endTime;
    double _selectionStart;
    double _selectionEnd;
    BOOL _dragging;
    double _dragAnchor;
    PRCostUnit _costUnit;
    NSUInteger _frequency;
    NSString *_caption;
}

@property (nonatomic, weak) id<PRTimelineViewDelegate> delegate;
@property (nonatomic, assign) PRCostUnit costUnit;
@property (nonatomic, assign) NSUInteger frequency;

/* Cost per equally sized time bucket, as PRProfile hands it out. */
- (void)setBuckets:(NSArray *)values
         startTime:(double)startTime
           endTime:(double)endTime;
/* Points of { "time", "value" } for a profile that carries a curve of its
   own, such as heap consumption over time. */
- (void)setCurve:(NSArray *)points caption:(NSString *)caption;
- (void)clear;

- (PRTimeRange)selectedRange;
- (void)clearSelection;

@end
