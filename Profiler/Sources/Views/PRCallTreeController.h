/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "PRTypes.h"

@class PRCallNode;

/* Feeds an outline view with a call tree, either from the outermost frame
   downwards or from the hot leaves back to their callers. */
/* The outline view data source and delegate methods are implemented
   informally: the formal protocols of this AppKit version require every
   optional method as well. */
@interface PRCallTreeController : NSObject
{
    PRCallNode *_root;
    PRCostUnit _costUnit;
    NSUInteger _frequency;
    double _total;
}

@property (nonatomic, assign) PRCostUnit costUnit;
@property (nonatomic, assign) NSUInteger frequency;

- (void)configureOutlineView:(NSOutlineView *)outlineView;
- (void)setRoot:(PRCallNode *)root inOutlineView:(NSOutlineView *)outlineView;
/* Opens the heaviest path so the hot spot is visible without clicking. */
- (void)expandHotPathInOutlineView:(NSOutlineView *)outlineView
                          maxDepth:(NSUInteger)maxDepth;

@end
