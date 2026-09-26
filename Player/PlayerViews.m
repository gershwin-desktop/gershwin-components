/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerViews.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

// EWMH _NET_WM_STATE actions
enum { NetWMStateRemove = 0, NetWMStateAdd = 1 };

static void PlayerXWindowOf(NSWindow *window, Display **display, Window *xid)
{
    GSDisplayServer *server = GSServerForWindow(window);
    *display = (Display *)[server serverDevice];
    *xid = (Window)(uintptr_t)[server windowDevice:[window windowNumber]];
    if (!*display || !*xid) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"no X11 window for %@", window];
    }
}

// Whether the window manager lists the atom in _NET_SUPPORTED
static BOOL windowManagerSupports(Display *display, Atom atom)
{
    Atom supported = XInternAtom(display, "_NET_SUPPORTED", False);
    Atom type = None;
    int format = 0;
    unsigned long count = 0, remaining = 0;
    unsigned char *data = NULL;
    BOOL found = NO;

    if (XGetWindowProperty(display, DefaultRootWindow(display), supported, 0, 65536,
                           False, XA_ATOM, &type, &format, &count, &remaining,
                           &data) == Success && data) {
        const Atom *atoms = (const Atom *)data;
        for (unsigned long i = 0; i < count && !found; i++) {
            found = (atoms[i] == atom);
        }
        XFree(data);
    }
    return found;
}

void PlayerSetWindowFullScreen(NSWindow *window, BOOL fullScreen)
{
    Display *display = NULL;
    Window xid = 0;
    PlayerXWindowOf(window, &display, &xid);

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

static int32_t fixed(double v)
{
    return (int32_t)lround(v * 65536.0);
}

NSData *PlayerBottomCurveShapePath(CGFloat depth, CGFloat radius)
{
    // Points: fraction of the width, pixels, fraction of the height, pixels.
    // The bottom is a parabola between the rounded corners (a cubic with its
    // control points a third in from each end), deepest in the middle, where
    // it touches the bottom.  Each corner is a quarter circle as a cubic.
    const double k = 0.5522847498;   // control distance of a quarter circle
    double d = depth;
    double r = radius;
    int32_t v[] = {
        1,
        0, 0, 0, 0, 0,
        1, fixed(1), 0, 0, 0,
        1, fixed(1), 0, fixed(1), fixed(-(d + r)),
        2, fixed(1), 0, fixed(1), fixed(-(d + r) + k * r),
           fixed(1), fixed(-r + k * r), fixed(1), fixed(-d),
           fixed(1), fixed(-r), fixed(1), fixed(-d),
        2, fixed(2.0 / 3), fixed(-r / 3), fixed(1), fixed(d / 3),
           fixed(1.0 / 3), fixed(r / 3), fixed(1), fixed(d / 3),
           0, fixed(r), fixed(1), fixed(-d),
        2, 0, fixed(r - k * r), fixed(1), fixed(-d),
           0, 0, fixed(1), fixed(-(d + r) + k * r),
           0, 0, fixed(1), fixed(-(d + r)),
        3
    };
    return [NSData dataWithBytes:v length:sizeof(v)];
}




void PlayerSetWindowShapePath(NSWindow *window, NSData *path)
{
    Display *display = NULL;
    Window xid = 0;
    PlayerXWindowOf(window, &display, &xid);
    Atom pathAtom = XInternAtom(display, "_WM_SHAPE_PATH", False);

    if (path && windowManagerSupports(display, pathAtom)) {
        NSUInteger count = [path length] / sizeof(int32_t);
        const int32_t *values = [path bytes];
        // Xlib takes 32-bit property items as longs
        long items[count];
        for (NSUInteger i = 0; i < count; i++) {
            items[i] = values[i];
        }
        XChangeProperty(display, xid, pathAtom, XA_INTEGER, 32, PropModeReplace,
                        (unsigned char *)items, (int)count);
    } else {
        XDeleteProperty(display, xid, pathAtom);
    }
    XFlush(display);
}

@implementation PlayerWindow

- (void)setBottomCurveDepth:(CGFloat)depth cornerRadius:(CGFloat)radius
{
    if (depth == _bottomCurveDepth && radius == _bottomCornerRadius) {
        return;
    }
    _bottomCurveDepth = depth;
    _bottomCornerRadius = depth > 0 ? radius : 0;

    NSData *path = nil;
    if (depth > 0) {
        // The outline is in device pixels
        NSRect points = [[self contentView] bounds];
        NSRect pixels = [[self contentView] convertRect:points toView:nil];
        CGFloat scale = NSWidth(points) > 0 ? NSWidth(pixels) / NSWidth(points) : 1.0;
        path = PlayerBottomCurveShapePath(round(depth * scale),
                                          round(_bottomCornerRadius * scale));
    }
    PlayerSetWindowShapePath(self, path);
}

@end

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

- (void)setBlackBackground:(BOOL)black
{
    if (black != _blackBackground) {
        _blackBackground = black;
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)rect
{
    // Opaque, so hidden views leave no stale pixels behind; black in full
    // screen, where the picture is all there is to see
    [(_blackBackground ? [NSColor blackColor] : [NSColor windowBackgroundColor]) set];
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

NSTextField *PlayerMakeLabel(NSFont *font)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setFont:font];
    [[label cell] setWraps:NO];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    return label;
}

