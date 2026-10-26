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


/// A one-line label that shortens text too long for it in the middle, so
/// the start and the end of a title stay readable.
NSTextField *PlayerMakeLabel(NSFont *font);

/// A toolbar-like strip: a subtle vertical gradient (lighter at the top, so
/// it reads as a surface the window's frame continues into) with a hairline
/// at one edge. Same treatment as FMRackNew's FMBarView, behind the search
/// row above the carousel in Radio/Podcast mode.
@interface PlayerBarView : NSView
@property (nonatomic, assign) BOOL hairlineAtBottom;
@end

/// A seek bar: a track with a playhead at the current time and small tick
/// marks for chapters. Click or drag anywhere to scrub; -action fires once
/// the mouse goes up, the same "seek once, not while dragging" rule
/// PlayerController's plain time slider uses.
///
/// Plain NSView, not NSControl: a bare NSControl subclass gets a plain
/// NSCell by default, which does not support target/action and raises
/// NSInternalInconsistencyException ("attempt to set a target in an
/// NSCell") the moment -setTarget: is called - nothing else here uses a
/// cell, so target/action/enabled are just ivars.
@interface PlayerTimelineView : NSView
{
    NSTimeInterval _duration;
    NSTimeInterval _currentTime;
    NSArray *_chapterTimes;    // NSNumber seconds, ascending, parallel to _chapterTitles
    NSArray *_chapterTitles;   // NSString, parallel to _chapterTimes
    id _target;
    SEL _action;
    BOOL _enabled;
}
@property (nonatomic, assign) id target;
@property (nonatomic, assign) SEL action;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) NSTimeInterval currentTime;
- (void)setDuration:(NSTimeInterval)duration;
- (void)setCurrentTime:(NSTimeInterval)seconds;
/// Chapter tick marks; times (seconds) and titles (shown as a tooltip when
/// hovering a mark) in the same order. Either nil, or both the same
/// length; nil/empty draws no marks.
- (void)setChapterTimes:(NSArray *)times titles:(NSArray *)titles;
@end

/// Asks the window manager to show the window full screen (above the menu
/// bar and the Dock, without titlebar) or to bring it back; the window
/// manager restores the previous frame itself.
void PlayerSetWindowFullScreen(NSWindow *window, BOOL fullScreen);

/// _WM_SHAPE_PATH value (32-bit integers) for a window whose bottom edge
/// curves down towards the middle, `depth` pixels higher at the sides, with
/// the bottom corners rounded by `radius` pixels.
NSData *PlayerBottomCurveShapePath(CGFloat depth, CGFloat radius);




/// Asks the window manager for this outline on the window (nil: none).
/// Does nothing when the window manager does not draw outlines.
void PlayerSetWindowShapePath(NSWindow *window, NSData *path);

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
