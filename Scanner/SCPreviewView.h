/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCPreviewView;

@protocol SCPreviewViewDelegate <NSObject>
- (void) previewViewSelectionsDidChange: (SCPreviewView *)view;
@end

/*
 * Shows the preview scan of the whole bed and lets the user draw, move,
 * resize and delete the areas to scan. Selections are kept as fractions of
 * the bed (origin top left, like the scanner's coordinates), so they stay
 * valid at every zoom level and preview resolution.
 */
@interface SCPreviewView : NSView

@property (nonatomic, weak) id<SCPreviewViewDelegate> delegate;
@property (nonatomic, strong) NSImage *image;
/* Width / height of the full bed, so the empty view has the right shape */
@property (nonatomic) NSSize bedAspect;
/* 0 means fit into the visible area */
@property (nonatomic) CGFloat zoom;

- (NSArray *) selections;            /* NSValue rects, in drawing order */
- (void) setSelections: (NSArray *)selections;
- (NSInteger) activeSelection;       /* -1 when none */
- (void) addSelection: (NSRect)fraction;
- (void) removeActiveSelection;
- (void) removeAllSelections;
/* Replaces the active selection, or adds one when there is none */
- (void) setActiveSelectionRect: (NSRect)fraction;

- (void) zoomIn;
- (void) zoomOut;
- (void) zoomToFit;
- (void) updateSize;

@end
