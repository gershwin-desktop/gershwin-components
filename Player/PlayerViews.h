/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerViews_h
#define PlayerViews_h

#import <AppKit/AppKit.h>

/**
 * What the player window's content view hands to its controller: dropped
 * files and the keys that work anywhere in the window.
 */
@protocol PlayerContentViewController <NSObject>
- (void)handleDroppedFiles:(NSArray *)paths;
/// Returns NO if the key is not one of the player's keys.
- (BOOL)handleKeyDown:(NSEvent *)event;
- (void)contentViewDragEntered:(BOOL)entered;
@end

/// Content view of the player window: accepts dropped files and the
/// player's keys (Space, arrows, Escape) wherever the focus is.
@interface PlayerContentView : NSView
{
    id<PlayerContentViewController> _controller;   // not retained
    BOOL _blackBackground;
}
/// Black behind the picture in full screen instead of the window colour.
- (void)setBlackBackground:(BOOL)black;
- (instancetype)initWithFrame:(NSRect)frame
                   controller:(id<PlayerContentViewController>)controller;
@end

/// Shows decoded RGBA video frames, scaled to fit with black bars.
@interface VideoRenderView : NSView
{
    NSBitmapImageRep *_rep;
}
- (void)setFrameData:(NSData *)data width:(int)width height:(int)height;
- (void)clear;
@end

/// Holds the controls in full screen, without a look of its own.
@interface PlayerOverlayBarView : NSView
@end

/// A one-line label that shortens text too long for it in the middle, so
/// the start and the end of a title stay readable.
NSTextField *PlayerMakeLabel(NSFont *font);

/// Asks the window manager to show the window full screen (above the menu
/// bar and the Dock, without titlebar) or to bring it back; the window
/// manager restores the previous frame itself.
void PlayerSetWindowFullScreen(NSWindow *window, BOOL fullScreen);

/// _WM_SHAPE_PATH value (32-bit integers) for a window whose bottom edge
/// curves down towards the middle, `depth` pixels higher at the sides, with
/// the bottom corners rounded by `radius` pixels.
NSData *PlayerBottomCurveShapePath(CGFloat depth, CGFloat radius);

/// The player window: its bottom edge curves down towards the middle, drawn
/// by the window manager when it supports window outlines (_WM_SHAPE_PATH).
@interface PlayerWindow : NSWindow
{
    CGFloat _bottomCurveDepth;
    CGFloat _bottomCornerRadius;
}
/// How much higher the bottom edge is at the sides than in the middle, and
/// how round its corners are, in points; depth 0 makes the window a plain
/// rectangle.
- (void)setBottomCurveDepth:(CGFloat)depth cornerRadius:(CGFloat)radius;
@end

#endif /* PlayerViews_h */
