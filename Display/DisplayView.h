/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "DisplayArrangement.h"

@class DisplayController;
@class DisplayOutput;

// Custom view that represents a single display rectangle
@interface DisplayRectView : NSView
{
    BOOL isDragging;
    BOOL didMove;
    NSPoint dragOffset;
}

@property (retain) DisplayOutput *output;
/* Shown instead of the output's name when set (mirrored outputs). */
@property (copy) NSString *label;
@property BOOL showsMenuBar;
@property BOOL isSelected;
@property BOOL isDraggingMenuBar;
@property BOOL isMenuBarDropTarget;

@end

// Main view that contains all display rectangles and handles arrangement.
// It only ever shows the controller's layout; the rectangles' positions are
// view coordinates and never written back into the model.
@interface DisplayView : NSView
{
    DisplayController *controller;
    NSMutableArray *displayRects;
    DisplayViewMapping mapping;
}

@property (assign) DisplayController *controller;

- (void)updateDisplayRects;
- (NSArray *)displayRects;
- (DisplayViewMapping)mapping;

@end
