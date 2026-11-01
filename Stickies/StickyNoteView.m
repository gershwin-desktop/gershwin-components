/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StickyNoteView.h"
#import "StickyNoteController.h"
#import "StickyNoteWindow.h"

#define TITLE_BAR_HEIGHT 22.0
#define BUTTON_SIZE 12.0
#define BUTTON_MARGIN 6.0
#define RESIZE_HANDLE_SIZE 12.0

@implementation StickyNoteView

@synthesize backgroundColor;
@synthesize textView;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [NSColor yellowColor];

        NSRect scrollRect = NSMakeRect(0, TITLE_BAR_HEIGHT,
                                        frame.size.width,
                                        frame.size.height - TITLE_BAR_HEIGHT);

        scrollView = [[NSScrollView alloc] initWithFrame:scrollRect];
        [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [scrollView setBorderType:NSNoBorder];
        [scrollView setHasVerticalScroller:NO];
        [scrollView setHasHorizontalScroller:NO];
        [scrollView setDrawsBackground:NO];
        [[scrollView contentView] setDrawsBackground:NO];

        textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0,
                                               scrollRect.size.width,
                                               scrollRect.size.height)];
        [textView setDrawsBackground:NO];
        [textView setRichText:YES];
        [textView setUsesFontPanel:YES];
        [textView setUsesFindPanel:YES];
        [textView setFont:[NSFont fontWithName:@"Helvetica" size:14.0]];
        [textView setAutoresizingMask:NSViewWidthSizable];

        [scrollView setDocumentView:textView];
        [textView release];

        [self addSubview:scrollView];
        [scrollView release];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect bounds = [self bounds];
    BOOL isKey = [[self window] isKeyWindow];

    [backgroundColor set];
    NSRectFill(bounds);

    if (isKey) {
        NSColor *darker = [backgroundColor blendedColorWithFraction:0.2 ofColor:[NSColor blackColor]];
        if (!darker) darker = backgroundColor;
        [darker set];
        NSRect titleBar = NSMakeRect(0, 0, bounds.size.width, TITLE_BAR_HEIGHT);
        NSRectFill(titleBar);

        CGFloat buttonY = (TITLE_BAR_HEIGHT - BUTTON_SIZE) / 2;
        CGFloat closeX = BUTTON_MARGIN;

        NSRect closeRect = NSMakeRect(closeX, buttonY, BUTTON_SIZE, BUTTON_SIZE);
        [[NSColor colorWithDeviceRed:0.9 green:0.3 blue:0.3 alpha:1.0] set];
        [[NSBezierPath bezierPathWithOvalInRect:closeRect] fill];

        [[NSColor whiteColor] set];
        [NSBezierPath setDefaultLineWidth:2.0];
        NSBezierPath *xPath = [NSBezierPath bezierPath];
        [xPath moveToPoint:NSMakePoint(NSMinX(closeRect) + 3.5, NSMinY(closeRect) + 3.5)];
        [xPath lineToPoint:NSMakePoint(NSMaxX(closeRect) - 3.5, NSMaxY(closeRect) - 3.5)];
        [xPath moveToPoint:NSMakePoint(NSMaxX(closeRect) - 3.5, NSMinY(closeRect) + 3.5)];
        [xPath lineToPoint:NSMakePoint(NSMinX(closeRect) + 3.5, NSMaxY(closeRect) - 3.5)];
        [xPath stroke];

        if ([(StickyNoteWindow *)[self window] isCollapsed]) return;

        NSColor *resizeColor = [darker blendedColorWithFraction:0.3 ofColor:[NSColor blackColor]];
        if (!resizeColor) resizeColor = [NSColor darkGrayColor];
        [resizeColor set];
        CGFloat rx = bounds.size.width - RESIZE_HANDLE_SIZE;
        CGFloat ry = bounds.size.height - RESIZE_HANDLE_SIZE;
        // The view is flipped: the grip fills the lower right half of the
        // handle square, with its hypotenuse facing the note's text.
        NSBezierPath *grip = [NSBezierPath bezierPath];
        [grip moveToPoint:NSMakePoint(rx + RESIZE_HANDLE_SIZE, ry)];
        [grip lineToPoint:NSMakePoint(rx + RESIZE_HANDLE_SIZE, ry + RESIZE_HANDLE_SIZE)];
        [grip lineToPoint:NSMakePoint(rx, ry + RESIZE_HANDLE_SIZE)];
        [grip closePath];
        [grip fill];
    }
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)isInTitleBar:(NSPoint)point
{
    return (point.y >= 0 && point.y < TITLE_BAR_HEIGHT);
}

- (NSRect)resizeHandleRect
{
    NSRect bounds = [self bounds];
    return NSMakeRect(bounds.size.width - RESIZE_HANDLE_SIZE,
                       bounds.size.height - RESIZE_HANDLE_SIZE,
                       RESIZE_HANDLE_SIZE, RESIZE_HANDLE_SIZE);
}

- (BOOL)isInResizeHandle:(NSPoint)point
{
    // A rolled-up note is only its title bar; the corner there belongs to it.
    if ([(StickyNoteWindow *)[self window] isCollapsed]) return NO;
    return NSPointInRect(point, [self resizeHandleRect]);
}

// The scroll view's text view fills the same corner and establishes its own
// I-beam cursor rect there (-[NSTextView resetCursorRects] covers its whole
// visible rect); because it is the deepest view, its rect always wins over
// one added here. A tracking rect fires -mouseEntered:/-mouseExited:
// independently of that resolution order and even while the window is not
// key (unlike cursor rects, gated to the key window), so it reliably shows
// the arrow over the grip.
- (void)updateResizeCursorTracking
{
    if (resizeCursorTag != 0) {
        [self removeTrackingRect:resizeCursorTag];
        resizeCursorTag = 0;
    }
    if ([self window] != nil && ![(StickyNoteWindow *)[self window] isCollapsed]) {
        resizeCursorTag = [self addTrackingRect:[self resizeHandleRect]
                                           owner:self
                                        userData:NULL
                                    assumeInside:NO];
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self updateResizeCursorTracking];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [self updateResizeCursorTracking];
}

- (void)mouseEntered:(NSEvent *)event
{
    [[NSCursor arrowCursor] set];
}

- (void)mouseExited:(NSEvent *)event
{
    [[NSCursor IBeamCursor] set];
}

- (NSView *)hitTest:(NSPoint)aPoint
{
    // The text scroll view reaches into the grip corner; the grip must win.
    if (NSPointInRect(aPoint, [self frame]) &&
        [self isInResizeHandle:[self convertPoint:aPoint fromView:[self superview]]]) {
        return self;
    }
    return [super hitTest:aPoint];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    if ([self isInResizeHandle:point]) {
        resizing = YES;
        // Screen coordinates, because the window moves under the pointer
        // while its top edge stays put.
        resizeStartPoint = [NSEvent mouseLocation];
        resizeStartFrame = [[self window] frame];
        return;
    }

    if ([self isInTitleBar:point]) {
        CGFloat buttonY = (TITLE_BAR_HEIGHT - BUTTON_SIZE) / 2;
        CGFloat closeX = BUTTON_MARGIN;

        if (point.x >= closeX && point.x <= closeX + BUTTON_SIZE &&
            point.y >= buttonY && point.y <= buttonY + BUTTON_SIZE) {
            id delegate = [(NSWindow *)[self window] delegate];
            if (delegate && [delegate respondsToSelector:@selector(closeNote)]) {
                [delegate closeNote];
            }
            return;
        }

        [[self window] mouseDown:event];
    } else {
        [super mouseDown:event];
    }
}

- (void)mouseDragged:(NSEvent *)event
{
    if (resizing) {
        NSPoint current = [NSEvent mouseLocation];
        NSSize newSize = resizeStartFrame.size;
        newSize.width += current.x - resizeStartPoint.x;
        newSize.height -= current.y - resizeStartPoint.y;
        if (newSize.width < 100) newSize.width = 100;
        if (newSize.height < 80) newSize.height = 80;
        NSRect newFrame = resizeStartFrame;
        newFrame.origin.y -= newSize.height - resizeStartFrame.size.height;
        newFrame.size = newSize;
        [[self window] setFrame:newFrame display:YES animate:NO];
        return;
    }
    [super mouseDragged:event];
}

- (void)mouseUp:(NSEvent *)event
{
    if (resizing) {
        resizing = NO;
        return;
    }
    [super mouseUp:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    if ([self isInTitleBar:point]) {
        NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Note Context"];
        [contextMenu addItemWithTitle:@"Close" action:@selector(closeNote:) keyEquivalent:@""];
        [contextMenu addItem:[NSMenuItem separatorItem]];
        [contextMenu addItemWithTitle:@"Float on Top" action:@selector(makeFloatOnTop:) keyEquivalent:@""];
        [contextMenu addItemWithTitle:@"Translucent" action:@selector(makeTranslucent:) keyEquivalent:@""];
        [contextMenu addItem:[NSMenuItem separatorItem]];
        [contextMenu addItemWithTitle:@"Note Info" action:@selector(showNoteInfo:) keyEquivalent:@""];
        [contextMenu popUpMenuPositioningItem:nil atLocation:point inView:self];
        [contextMenu release];
    }
}

- (void)setNoteColor:(NSColor *)color
{
    [color retain];
    [backgroundColor release];
    backgroundColor = color;
    [self setNeedsDisplay:YES];
}

- (void)dealloc
{
    // -addTrackingRect:owner:userData:assumeInside: does not retain its
    // owner; a rect left registered past this point would reference a
    // freed view.
    if (resizeCursorTag != 0) {
        [self removeTrackingRect:resizeCursorTag];
    }
    [backgroundColor release];
    [super dealloc];
}

@end