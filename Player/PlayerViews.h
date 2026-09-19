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
 * files, the keys that work anywhere in the window, and mouse movement
 * (to show the controls in full screen).
 */
@protocol PlayerContentViewController <NSObject>
- (void)handleDroppedFiles:(NSArray *)paths;
/// Returns NO if the key is not one of the player's keys.
- (BOOL)handleKeyDown:(NSEvent *)event;
- (void)contentViewMouseMoved:(NSEvent *)event;
- (void)contentViewDragEntered:(BOOL)entered;
@end

/// Content view of the player window: accepts dropped files and the
/// player's keys (Space, arrows, Escape) wherever the focus is.
@interface PlayerContentView : NSView
{
    id<PlayerContentViewController> _controller;   // not retained
}
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

/// The dark strip behind the controls in full screen.
@interface OverlayBarView : NSView
@end

/// A one-line label that shortens text too long for it in the middle, so
/// the start and the end of a title stay readable.
NSTextField *PlayerMakeLabel(NSFont *font);

/// Asks the window manager to show the window full screen (above the menu
/// bar and the Dock, without titlebar) or to bring it back; the window
/// manager restores the previous frame itself.
void PlayerSetWindowFullScreen(NSWindow *window, BOOL fullScreen);

#endif /* PlayerViews_h */
