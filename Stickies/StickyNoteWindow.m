/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickyNoteWindow.h"
#import "StickyNoteView.h"
#import "StickyNoteController.h"
#import "StickyWorkArea.h"

#define TITLE_BAR_HEIGHT 22.0
#define MAX_SCREEN_SHARE 0.8

@implementation StickyNoteWindow

@synthesize isCollapsed;
@synthesize expandedFrame;
@synthesize mouseDownInTitleBar;
@synthesize mouseDownLocation;

- (id)initWithContentRect:(NSRect)contentRect
                styleMask:(NSUInteger)styleMask
                  backing:(NSBackingStoreType)bufferingType
                    defer:(BOOL)deferCreation
{
    self = [super initWithContentRect:contentRect
                            styleMask:NSBorderlessWindowMask
                              backing:bufferingType
                                defer:deferCreation];
    if (self) {
        [self setOpaque:NO];
        [self setHasShadow:YES];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setAcceptsMouseMovedEvents:YES];
        [self setLevel:NSFloatingWindowLevel];
        [self setReleasedWhenClosed:NO];
        isCollapsed = NO;
        expandedFrame = contentRect;
        mouseDownInTitleBar = NO;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow
{
    return YES;
}

- (BOOL)canBecomeMainWindow
{
    return YES;
}

- (BOOL)isMovable
{
    return NO;
}

- (void)collapse
{
    if (isCollapsed) return;
    isCollapsed = YES;
    expandedFrame = [self frame];
    NSRect r = expandedFrame;
    r.size.height = TITLE_BAR_HEIGHT + 4;
    // Screen coordinates grow upward; keep the title bar in place so the
    // note rolls up into it instead of dropping to its bottom edge.
    r.origin.y = NSMaxY(expandedFrame) - r.size.height;
    [self setFrame:r display:YES animate:YES];
    StickyNoteController *controller = (StickyNoteController *)[self delegate];
    if (controller) {
        [controller setCollapsed:YES];
    }
}

- (void)expand
{
    if (!isCollapsed) return;
    NSRect r = [self uncollapsedFrame];
    isCollapsed = NO;
    [self setFrame:r display:YES animate:YES];
    StickyNoteController *controller = (StickyNoteController *)[self delegate];
    if (controller) {
        [controller setCollapsed:NO];
    }
}

- (NSRect)frameBelowReservedTopArea:(NSRect)frameRect
{
    // Borderless windows are not constrained by NSWindow, and the window
    // manager does not place them, so keep the title bar out of struts such
    // as the menu bar ourselves; otherwise the note can no longer be grabbed.
    NSRect usable = [StickyWorkArea usableFrameOfScreen:[self screen]];
    if (NSMaxY(frameRect) > NSMaxY(usable)) {
        frameRect.origin.y = NSMaxY(usable) - NSHeight(frameRect);
    }
    return frameRect;
}

- (NSRect)frameFittingScreen:(NSRect)frameRect
{
    // Notes saved on a larger screen must stay graspable and leave room for
    // other windows, so cap them to a share of the usable area first.
    NSRect usable = [StickyWorkArea usableFrameOfScreen:[self screen]];
    CGFloat maxWidth = floor(NSWidth(usable) * MAX_SCREEN_SHARE);
    CGFloat maxHeight = floor(NSHeight(usable) * MAX_SCREEN_SHARE);
    if (NSWidth(frameRect) > maxWidth) {
        frameRect.size.width = maxWidth;
    }
    if (NSHeight(frameRect) > maxHeight) {
        frameRect.origin.y = NSMaxY(frameRect) - maxHeight;
        frameRect.size.height = maxHeight;
    }

    frameRect = [self frameBelowReservedTopArea:frameRect];
    if (NSMinY(frameRect) < NSMinY(usable)) {
        frameRect.origin.y = NSMinY(usable);
    }
    if (NSMaxX(frameRect) > NSMaxX(usable)) {
        frameRect.origin.x = NSMaxX(usable) - NSWidth(frameRect);
    }
    if (NSMinX(frameRect) < NSMinX(usable)) {
        frameRect.origin.x = NSMinX(usable);
    }
    return frameRect;
}

- (NSRect)uncollapsedFrame
{
    if (!isCollapsed) return [self frame];
    // The note may have been dragged while rolled up; unroll it below
    // wherever its title bar is now.
    NSRect current = [self frame];
    NSRect r = expandedFrame;
    r.origin.x = current.origin.x;
    r.origin.y = NSMaxY(current) - r.size.height;
    return r;
}

- (void)toggleCollapse
{
    if (isCollapsed) {
        [self expand];
    } else {
        [self collapse];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    // NSApplication asks the key window before the main menu, so a note window
    // handles Cmd-S here although no menu item carries that shortcut.
    if ([event type] == NSKeyDown &&
        ([event modifierFlags] & (NSControlKeyMask | NSAlternateKeyMask |
                                  NSCommandKeyMask)) == NSCommandKeyMask) {
        NSString *key = [[event charactersIgnoringModifiers] lowercaseString];
        id controller = [self delegate];
        if ([key isEqualToString:@"s"] &&
            [controller respondsToSelector:@selector(saveNow)]) {
            [controller saveNow];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

// Multiple notes share one window level (NSFloatingWindowLevel), so their
// relative z-order is ours to manage; nothing else raises the one the user
// just clicked. -sendEvent: is the single choke point every mouse-down
// passes through before AppKit hit-tests it to a subview (title bar, resize
// grip, or straight into the text view), so it covers all of them.
- (void)sendEvent:(NSEvent *)event
{
    if ([event type] == NSLeftMouseDown) {
        [self makeKeyAndOrderFront:self];
    }
    [super sendEvent:event];
}

- (void)mouseDown:(NSEvent *)event
{
    StickyNoteView *cv = (StickyNoteView *)[self contentView];
    NSPoint viewPoint = [cv convertPoint:[event locationInWindow] fromView:nil];

    if ([cv isInTitleBar:viewPoint]) {
        mouseDownInTitleBar = YES;
        mouseDownLocation = [event locationInWindow];

        if ([event clickCount] == 2) {
            [self toggleCollapse];
            return;
        }
    } else {
        mouseDownInTitleBar = NO;
        [super mouseDown:event];
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    if (mouseDownInTitleBar) {
        NSPoint current = [event locationInWindow];
        NSPoint origin = [self frame].origin;
        origin.x += current.x - mouseDownLocation.x;
        origin.y += current.y - mouseDownLocation.y;
        NSRect r = [self frame];
        r.origin = origin;
        [self setFrameOrigin:[self frameBelowReservedTopArea:r].origin];
    } else {
        [super mouseDragged:event];
    }
}

- (void)mouseUp:(NSEvent *)event
{
    mouseDownInTitleBar = NO;
    [super mouseUp:event];
}

- (void)becomeKeyWindow
{
    [super becomeKeyWindow];
    [[self contentView] setNeedsDisplay:YES];
}

- (void)resignKeyWindow
{
    [super resignKeyWindow];
    [[self contentView] setNeedsDisplay:YES];
}

@end