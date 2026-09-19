/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerViews.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>

// EWMH _NET_WM_STATE actions
enum { NetWMStateRemove = 0, NetWMStateAdd = 1 };

void PlayerSetWindowFullScreen(NSWindow *window, BOOL fullScreen)
{
    GSDisplayServer *server = GSServerForWindow(window);
    Display *display = (Display *)[server serverDevice];
    Window xid = (Window)(uintptr_t)[server windowDevice:[window windowNumber]];
    if (!display || !xid) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"no X11 window for full screen"];
    }

    XEvent event;
    memset(&event, 0, sizeof(event));
    event.xclient.type = ClientMessage;
    event.xclient.window = xid;
    event.xclient.message_type = XInternAtom(display, "_NET_WM_STATE", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = fullScreen ? NetWMStateAdd : NetWMStateRemove;
    event.xclient.data.l[1] = XInternAtom(display, "_NET_WM_STATE_FULLSCREEN", False);
    event.xclient.data.l[2] = 0;
    event.xclient.data.l[3] = 1;   // source: an application
    XSendEvent(display, DefaultRootWindow(display), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
}

@implementation PlayerContentView

- (instancetype)initWithFrame:(NSRect)frame
                   controller:(id<PlayerContentViewController>)controller
{
    self = [super initWithFrame:frame];
    if (self) {
        _controller = controller;
        [self registerForDraggedTypes:@[NSFilenamesPboardType]];
    }
    return self;
}

// Holds the keyboard focus when no text field has it, so Space and the
// arrow keys reach the player.
- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)keyDown:(NSEvent *)event
{
    if (![_controller handleKeyDown:event]) {
        [super keyDown:event];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    [[self window] makeFirstResponder:self];
}

- (void)mouseMoved:(NSEvent *)event
{
    [_controller contentViewMouseMoved:event];
}

- (void)drawRect:(NSRect)rect
{
    // Opaque, so hidden views leave no stale pixels behind
    [[NSColor windowBackgroundColor] set];
    NSRectFill(rect);
}

- (BOOL)isOpaque
{
    return YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    if ([[[sender draggingPasteboard] types] containsObject:NSFilenamesPboardType]) {
        [_controller contentViewDragEntered:YES];
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    [_controller contentViewDragEntered:NO];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    [_controller contentViewDragEntered:NO];
    NSArray *files = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    if ([files count] == 0) {
        return NO;
    }
    [_controller handleDroppedFiles:files];
    return YES;
}

@end

@implementation VideoRenderView

- (void)dealloc
{
    [_rep release];
    [super dealloc];
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)setFrameData:(NSData *)data width:(int)width height:(int)height
{
    NSInteger bytesPerRow = (NSInteger)width * 4;
    if (width <= 0 || height <= 0 || (NSInteger)[data length] < bytesPerRow * height) {
        return;
    }

    if (!_rep || [_rep pixelsWide] != width || [_rep pixelsHigh] != height) {
        [self clear];
        _rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:width
                          pixelsHigh:height
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:bytesPerRow
                        bitsPerPixel:32];
    }
    memcpy([_rep bitmapData], [data bytes], bytesPerRow * height);
    // Frames arrive from the decoding thread, not from an event; draw now,
    // as damage would otherwise wait for the next X event
    [self setNeedsDisplay:YES];
    [[self window] displayIfNeeded];
}

- (void)clear
{
    [_rep release];
    _rep = nil;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor blackColor] set];
    NSRectFill(dirtyRect);
    if (!_rep) {
        return;
    }

    NSRect bounds = [self bounds];
    CGFloat w = [_rep pixelsWide];
    CGFloat h = [_rep pixelsHigh];
    CGFloat scale = MIN(NSWidth(bounds) / w, NSHeight(bounds) / h);
    NSRect dst = NSMakeRect(0, 0, floor(w * scale), floor(h * scale));
    dst.origin.x = floor(NSMidX(bounds) - NSWidth(dst) / 2.0);
    dst.origin.y = floor(NSMidY(bounds) - NSHeight(dst) / 2.0);
    // The bitmap itself, not an NSImage: that would cache the first frame
    // and show it for good
    [_rep drawInRect:dst];
}

@end

@implementation OverlayBarView

- (void)drawRect:(NSRect)rect
{
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.6] set];
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);
}

@end
