/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/NSWindow.h>

@interface StickyNoteWindow : NSWindow
{
    BOOL isCollapsed;
    NSRect expandedFrame;
    BOOL mouseDownInTitleBar;
    NSPoint mouseDownLocation;
}

@property (nonatomic, assign) BOOL isCollapsed;
@property (nonatomic, assign) NSRect expandedFrame;
@property (nonatomic, assign) BOOL mouseDownInTitleBar;
@property (nonatomic, assign) NSPoint mouseDownLocation;

- (void)collapse;
- (void)expand;
- (void)toggleCollapse;
- (NSRect)uncollapsedFrame;
- (NSRect)frameBelowReservedTopArea:(NSRect)frameRect;
- (NSRect)frameFittingScreen:(NSRect)frameRect;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)sendEvent:(NSEvent *)event;
/* Cmd-S saves now; the shortcut deliberately has no menu item. */
- (BOOL)performKeyEquivalent:(NSEvent *)event;

@end