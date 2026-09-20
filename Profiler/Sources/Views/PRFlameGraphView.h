/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

@class PRCallNode;
@class PRFlameGraphView;

@protocol PRFlameGraphViewDelegate <NSObject>
@optional
- (void)flameGraphView:(PRFlameGraphView *)view didHoverNode:(PRCallNode *)node;
- (void)flameGraphView:(PRFlameGraphView *)view didZoomToNode:(PRCallNode *)node;
@end

/* Draws a call tree as nested bars: one row per stack level, the width of
   a bar being the share of the cost that went through that call path.
   Clicking a bar zooms into it, which is the only practical way through a
   tree with thousands of leaves. */
@interface PRFlameGraphView : NSView
{
    PRCallNode *_root;
    PRCallNode *_zoomNode;
    PRCallNode *_hoverNode;
    NSMutableArray *_boxes;
    NSString *_searchString;
    PRCostUnit _costUnit;
    NSUInteger _frequency;
    CGFloat _rowHeight;
    double _matchedWeight;
    BOOL _boxesAreStale;
}

@property (nonatomic, weak) id<PRFlameGraphViewDelegate> delegate;
@property (nonatomic, assign) PRCostUnit costUnit;
@property (nonatomic, assign) NSUInteger frequency;
@property (nonatomic, copy) NSString *searchString;
@property (nonatomic, readonly, strong) PRCallNode *zoomNode;
/* Cost of the frames matching the search, for the "x % matched" readout. */
@property (nonatomic, readonly) double matchedWeight;

- (void)setRoot:(PRCallNode *)root;
- (void)zoomToNode:(PRCallNode *)node;
- (void)zoomOut;
- (void)resetZoom;

/* Height the view needs to show every level of the current tree. */
- (CGFloat)requiredHeight;
/* Human readable description of a bar, for the status line. */
- (NSString *)describeNode:(PRCallNode *)node;

@end
