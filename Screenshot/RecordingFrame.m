/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RecordingFrame.h"
#import "AppearanceMetrics.h"
#import "RecordingFrameGeometry.h"

/* Thickness of the frame around the area, in points. */
static const CGFloat kEdgeThickness = 4.0;
/* How far from a corner a press on an edge also moves the other side. */
static const CGFloat kCornerReach = 24.0;
/* Smallest area, in pixels, so the frame can always be taken hold of. */
static const CGFloat kMinimumSide = 32.0;
static const CGFloat kBarWidth = 460.0;
static const CGFloat kPopUpWidth = 80.0;
static const CGFloat kSizeFieldWidth = 50.0;
static const NSTimeInterval kPlacementEchoTime = 0.5;
static const CGFloat kLabelHeight = 17.0;
/* How close to a screen border a side has to come to be put on it, in
 * points. */
static const CGFloat kSnapReach = 16.0;

@interface RecordingFrame (Private)
- (void)layoutWindows;
- (CGFloat)scaleFactor;
- (void)resizeSides:(int)sides by:(NSPoint)delta from:(NSRect)startArea;
- (BOOL)canAdjust;
- (void)cancel:(id)sender;
- (BOOL)isEditingSize;
- (void)sizeEdited:(id)sender;
@end

/* One side of the frame.  It covers the corners at its ends, so the four
 * sides close the frame without gaps. */
@interface RecordingFrameEdgeView : NSView
{
    RecordingFrame *owner;
    int side;
    BOOL recording;
}
- (id)initWithOwner:(RecordingFrame *)owner side:(int)side;
- (void)setRecording:(BOOL)recording;
@end

@implementation RecordingFrameEdgeView

- (id)initWithOwner:(RecordingFrame *)anOwner side:(int)aSide
{
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        owner = anOwner;
        side = aSide;
    }
    return self;
}

- (void)setRecording:(BOOL)flag
{
    recording = flag;
    [self setNeedsDisplay:YES];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)drawRect:(NSRect)rect
{
    // Red while recording, as a recording light; a dark frame otherwise,
    // with a light line along it so it shows on dark and light content
    NSColor *fill = recording ? [NSColor colorWithCalibratedRed:0.85 green:0.1 blue:0.1 alpha:1.0]
                              : [NSColor colorWithCalibratedWhite:0.2 alpha:1.0];
    [fill set];
    NSRectFill([self bounds]);
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.8] set];
    NSRect b = [self bounds];
    NSRect line;
    switch (side) {
    case RecordingSideLeft: line = NSMakeRect(NSMaxX(b) - 1, 0, 1, NSHeight(b)); break;
    case RecordingSideRight: line = NSMakeRect(0, 0, 1, NSHeight(b)); break;
    case RecordingSideBottom: line = NSMakeRect(0, NSMaxY(b) - 1, NSWidth(b), 1); break;
    default: line = NSMakeRect(0, 0, NSWidth(b), 1); break;
    }
    NSRectFill(line);
}

/* Which sides a press here moves: its own, and the neighbour at a corner. */
- (int)sidesAtPoint:(NSPoint)p
{
    NSRect b = [self bounds];
    int sides = side;
    if (side == RecordingSideTop || side == RecordingSideBottom) {
        if (p.x < kCornerReach)
            sides |= RecordingSideLeft;
        else if (p.x > NSWidth(b) - kCornerReach)
            sides |= RecordingSideRight;
    } else {
        if (p.y < kCornerReach)
            sides |= RecordingSideBottom;
        else if (p.y > NSHeight(b) - kCornerReach)
            sides |= RecordingSideTop;
    }
    return sides;
}

- (void)mouseDown:(NSEvent *)event
{
    if (![owner canAdjust])
        return;
    int sides = [self sidesAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
    NSPoint start = [NSEvent mouseLocation];
    NSRect startArea = [owner area];

    for (;;) {
        NSEvent *next = [NSApp nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask
                                           untilDate:[NSDate distantFuture]
                                              inMode:NSEventTrackingRunLoopMode
                                             dequeue:YES];
        NSPoint now = [NSEvent mouseLocation];
        [owner resizeSides:sides by:NSMakePoint(now.x - start.x, now.y - start.y) from:startArea];
        if ([next type] == NSLeftMouseUp)
            break;
    }
}

@end

/* The controls, in a small titled palette above the frame: Return
 * records, Escape and its close button cancel, and dragging it by its title
 * moves the frame along until recording starts. */
@interface RecordingFrameBar : NSPanel
{
    RecordingFrame *owner;
}
- (void)setOwner:(RecordingFrame *)owner;
@end

@implementation RecordingFrameBar

- (void)setOwner:(RecordingFrame *)anOwner
{
    owner = anOwner;
}

- (void)sendEvent:(NSEvent *)event
{
    if ([event type] == NSKeyDown
        && [[event charactersIgnoringModifiers] isEqualToString:@"\033"]) {
        [owner cancel:self];
        return;
    }
    [super sendEvent:event];
}

/* Return in a size field applies the size; it must not also start
 * recording, and key equivalents (the Record button's Return) are looked
 * up before the field sees the key. */
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if ([owner isEditingSize]
        && [[event charactersIgnoringModifiers] isEqualToString:@"\r"]) {
        [self makeFirstResponder:self];
        [owner sizeEdited:self];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end

@implementation RecordingFrame

- (NSWindow *)borderlessWindowWithView:(NSView *)view
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                                   styleMask:NSBorderlessWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setReleasedWhenClosed:NO];
    [window setHidesOnDeactivate:NO];
    // Above the windows being recorded, which take the focus meanwhile
    [window setLevel:NSStatusWindowLevel];
    [window setContentView:view];
    return window;
}

- (NSButton *)barButtonWithTitle:(NSString *)title action:(SEL)action
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    [button setTitle:title];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    return [button autorelease];
}

- (NSTextField *)sizeFieldAtX:(CGFloat)x y:(CGFloat)y
{
    NSTextField *field = [[NSTextField alloc] initWithFrame:
        NSMakeRect(x, y, kSizeFieldWidth, METRICS_TEXT_INPUT_FIELD_HEIGHT)];
    [field setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [field setBezeled:YES];
    [field setEditable:YES];
    [field setAlignment:NSRightTextAlignment];
    [field setTarget:self];
    [field setAction:@selector(sizeEdited:)];
    return [field autorelease];
}

- (void)createBarWithFormat:(ScreenRecordingFormat)format
{
    CGFloat height = METRICS_SPACE_8 + METRICS_BUTTON_HEIGHT + METRICS_SPACE_8;
    CGFloat side = METRICS_SPACE_12;
    bar = [[RecordingFrameBar alloc] initWithContentRect:NSMakeRect(0, 0, kBarWidth, height)
                                               styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [(RecordingFrameBar *)bar setOwner:self];
    [bar setTitle:NSLocalizedString(@"Screen Recording", @"")];
    [bar setReleasedWhenClosed:NO];
    [bar setHidesOnDeactivate:NO];
    [(NSPanel *)bar setFloatingPanel:YES];
    // Floating, not status level like the frame: the backend makes status
    // windows docks, which never get the keyboard, and the size fields
    // need it
    [bar setLevel:NSFloatingWindowLevel];
    [bar setDelegate:(id)self];
    [bar setContentSize:NSMakeSize(kBarWidth, height)];
    NSView *view = [bar contentView];

    CGFloat y = METRICS_SPACE_8;
    formatPopUp = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(side, y, kPopUpWidth, METRICS_BUTTON_HEIGHT) pullsDown:NO];
    [formatPopUp addItemsWithTitles:[ScreenRecordingOptions formatNames]];
    [formatPopUp selectItemAtIndex:format];
    [formatPopUp setTarget:self];
    [formatPopUp setAction:@selector(formatChosen:)];
    [view addSubview:formatPopUp];

    recordButton = [[self barButtonWithTitle:NSLocalizedString(@"Record", @"")
                                      action:@selector(recordOrStop:)] retain];
    [recordButton setKeyEquivalent:@"\r"];
    [recordButton setFrame:NSMakeRect(kBarWidth - side - METRICS_BUTTON_MIN_WIDTH, y,
                                      METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
    [view addSubview:recordButton];

    cancelButton = [[self barButtonWithTitle:NSLocalizedString(@"Cancel", @"")
                                      action:@selector(cancel:)] retain];
    [cancelButton setFrame:NSMakeRect(NSMinX([recordButton frame]) - METRICS_BUTTON_HORIZ_INTERSPACE
                                      - METRICS_BUTTON_MIN_WIDTH, y,
                                      METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
    [view addSubview:cancelButton];

    CGFloat labelX = NSMaxX([formatPopUp frame]) + METRICS_SPACE_12;
    CGFloat spinnerSize = 16.0;
    spinner = [[NSProgressIndicator alloc] initWithFrame:
        NSMakeRect(labelX, floor((height - spinnerSize) / 2), spinnerSize, spinnerSize)];
    [spinner setStyle:NSProgressIndicatorSpinningStyle];
    [spinner setDisplayedWhenStopped:NO];
    [view addSubview:spinner];

    // Before recording the size can be typed in; it is applied with
    // Return or when leaving the field
    CGFloat fieldY = floor((height - METRICS_TEXT_INPUT_FIELD_HEIGHT) / 2);
    widthField = [[self sizeFieldAtX:labelX y:fieldY] retain];
    timesLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(NSMaxX([widthField frame]) + 4, floor((height - kLabelHeight) / 2), 12, kLabelHeight)];
    [timesLabel setEditable:NO];
    [timesLabel setSelectable:NO];
    [timesLabel setBezeled:NO];
    [timesLabel setDrawsBackground:NO];
    [timesLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [timesLabel setStringValue:@"\u00d7"];
    [view addSubview:timesLabel];
    heightField = [[self sizeFieldAtX:NSMaxX([timesLabel frame]) + 4 y:fieldY] retain];
    [view addSubview:widthField];
    [view addSubview:heightField];
    [widthField setNextKeyView:heightField];
    [heightField setNextKeyView:widthField];

    infoLabel = [[NSTextField alloc] initWithFrame:
        NSMakeRect(labelX, floor((height - kLabelHeight) / 2),
                   NSMinX([cancelButton frame]) - METRICS_SPACE_8 - labelX, kLabelHeight)];
    [infoLabel setEditable:NO];
    [infoLabel setSelectable:NO];
    [infoLabel setBezeled:NO];
    [infoLabel setDrawsBackground:NO];
    [infoLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
    [view addSubview:infoLabel];
}

- (id)initWithArea:(NSRect)anArea
            format:(ScreenRecordingFormat)format
          delegate:(id<RecordingFrameDelegate>)aDelegate
{
    self = [super init];
    if (self) {
        delegate = aDelegate;
        NSMutableArray *windows = [NSMutableArray array];
        int sides[4] = { RecordingSideLeft, RecordingSideRight, RecordingSideBottom, RecordingSideTop };
        for (int i = 0; i < 4; i++) {
            RecordingFrameEdgeView *view = [[[RecordingFrameEdgeView alloc]
                initWithOwner:self side:sides[i]] autorelease];
            NSWindow *window = [self borderlessWindowWithView:view];
            [windows addObject:window];
            [window release];
        }
        edges = [windows retain];
        [self createBarWithFormat:format];
        area = anArea;
        [self setRecordingState:RecordingFrameIdle];
    }
    return self;
}

- (void)dealloc
{
    // Ordered out, never closed: closing what looks like the application's
    // last window quits it, and the frame is no window of the user's
    [self close];
    [edges release];
    [bar release];
    [formatPopUp release];
    [infoLabel release];
    [lastPlacement release];
    [widthField release];
    [timesLabel release];
    [heightField release];
    [cancelButton release];
    [recordButton release];
    [spinner release];
    [super dealloc];
}

- (CGFloat)scaleFactor
{
    return [bar userSpaceScaleFactor];
}

- (NSRect)screenFrame
{
    return [[[NSScreen screens] objectAtIndex:0] frame];
}

- (void)show
{
    shown = YES;
    [self layoutWindows];
    [NSApp activateIgnoringOtherApps:YES];
    [bar makeKeyAndOrderFront:nil];
}

- (void)close
{
    shown = NO;
    [edges makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    [bar orderOut:nil];
}

- (NSRect)area
{
    return area;
}

- (void)setArea:(NSRect)newArea
{
    area = NSIntegralRect(newArea);
    [self layoutWindows];
    [widthField setIntValue:(int)NSWidth(area)];
    [heightField setIntValue:(int)NSHeight(area)];
}

- (NSRect)rootArea
{
    NSRect screen = [self screenFrame];
    return NSMakeRect(NSMinX(area) - NSMinX(screen),
                      NSMaxY(screen) - NSMaxY(area),
                      NSWidth(area), NSHeight(area));
}

- (void)layoutWindows
{
    CGFloat t = round(kEdgeThickness * [self scaleFactor]);
    NSRect a = area;
    // Left, right, bottom, top; the horizontal sides cover the corners
    NSRect frames[4] = {
        NSMakeRect(NSMinX(a) - t, NSMinY(a), t, NSHeight(a)),
        NSMakeRect(NSMaxX(a), NSMinY(a), t, NSHeight(a)),
        NSMakeRect(NSMinX(a) - t, NSMinY(a) - t, NSWidth(a) + 2 * t, t),
        NSMakeRect(NSMinX(a) - t, NSMaxY(a), NSWidth(a) + 2 * t, t)
    };
    // A side on a screen border has no room for its part of the frame,
    // and a window placed off the screen could be pushed back over the area
    // and recorded
    int onBorder = RecordingSidesOnScreenBorder(a, [self screenFrame]);
    int sides[4] = { RecordingSideLeft, RecordingSideRight, RecordingSideBottom, RecordingSideTop };
    for (int i = 0; i < 4; i++) {
        NSWindow *edge = [edges objectAtIndex:i];
        [edge setFrame:frames[i] display:YES];
        if (!shown || (onBorder & sides[i]))
            [edge orderOut:nil];
        else if (![edge isVisible])
            [edge orderFront:nil];
    }

    if (!followingBar)
        [self placeBar];
}

/* Above the frame, where a window has its title bar, or under it near the
 * top of the screen; inside the area only when there is room for neither.
 * Always within the work area, where the window manager leaves a window
 * where it is put, so that any move of the bar is the user's. */
- (void)placeBar
{
    CGFloat t = round(kEdgeThickness * [self scaleFactor]);
    NSRect a = area;
    NSRect work = [[[NSScreen screens] objectAtIndex:0] visibleFrame];
    NSRect barFrame = [bar frame];
    CGFloat x = round(NSMidX(a) - NSWidth(barFrame) / 2);
    x = MAX(NSMinX(work), MIN(x, NSMaxX(work) - NSWidth(barFrame)));
    CGFloat y = NSMaxY(a) + t;
    if (y + NSHeight(barFrame) > NSMaxY(work))
        y = NSMinY(a) - t - NSHeight(barFrame);
    if (y < NSMinY(work))
        y = MAX(NSMinY(work), MIN(NSMinY(a), NSMaxY(work) - NSHeight(barFrame)));
    placedBarOrigin = NSMakePoint(x, y);
    placingBar = YES;
    [bar setFrameOrigin:placedBarOrigin];
    placingBar = NO;
    [lastPlacement release];
    lastPlacement = [[NSDate alloc] init];
}

/* Dragging the bar by its title moves the frame along; while recording
 * the frame stays and the bar can be put out of the way. */
- (void)windowDidMove:(NSNotification *)notification
{
    if (placingBar || !shown)
        return;
    NSPoint origin = [bar frame].origin;
    if (NSEqualPoints(origin, placedBarOrigin))
        return;
    // The window manager reports a move some time after it is asked for,
    // and where the window ends up with its title bar, which differs a
    // little from what was asked; such an echo is no drag
    if (lastPlacement && -[lastPlacement timeIntervalSinceNow] < kPlacementEchoTime) {
        placedBarOrigin = origin;
        return;
    }
    if (state == RecordingFrameIdle) {
        NSRect moved = [self areaOnScreen:NSOffsetRect(area, origin.x - placedBarOrigin.x,
                                                       origin.y - placedBarOrigin.y)];
        followingBar = YES;
        [self setArea:RecordingSnapMove(moved, [self screenFrame], kSnapReach * [self scaleFactor])];
        followingBar = NO;
    }
    placedBarOrigin = origin;
}

- (BOOL)windowShouldClose:(id)sender
{
    [self cancel:self];
    return NO;
}

- (BOOL)canAdjust
{
    return state == RecordingFrameIdle;
}

/* Keeps the area on the screen. */
- (NSRect)areaOnScreen:(NSRect)r
{
    NSRect screen = [self screenFrame];
    r.size.width = MIN(NSWidth(r), NSWidth(screen));
    r.size.height = MIN(NSHeight(r), NSHeight(screen));
    r.origin.x = MAX(NSMinX(screen), MIN(NSMinX(r), NSMaxX(screen) - NSWidth(r)));
    r.origin.y = MAX(NSMinY(screen), MIN(NSMinY(r), NSMaxY(screen) - NSHeight(r)));
    return r;
}

- (void)resizeSides:(int)sides by:(NSPoint)delta from:(NSRect)startArea
{
    CGFloat minX = NSMinX(startArea), maxX = NSMaxX(startArea);
    CGFloat minY = NSMinY(startArea), maxY = NSMaxY(startArea);
    NSRect screen = [self screenFrame];

    if (sides & RecordingSideLeft)
        minX = MAX(NSMinX(screen), MIN(minX + delta.x, maxX - kMinimumSide));
    if (sides & RecordingSideRight)
        maxX = MIN(NSMaxX(screen), MAX(maxX + delta.x, minX + kMinimumSide));
    if (sides & RecordingSideBottom)
        minY = MAX(NSMinY(screen), MIN(minY + delta.y, maxY - kMinimumSide));
    if (sides & RecordingSideTop)
        maxY = MIN(NSMaxY(screen), MAX(maxY + delta.y, minY + kMinimumSide));
    [self setArea:RecordingSnapResize(NSMakeRect(minX, minY, maxX - minX, maxY - minY),
                                      sides, screen, kSnapReach * [self scaleFactor])];
}

- (RecordingFrameState)recordingState
{
    return state;
}

- (void)setRecordingState:(RecordingFrameState)newState
{
    state = newState;
    BOOL recording = (state == RecordingFrameRecording);
    for (NSWindow *edge in edges)
        [(RecordingFrameEdgeView *)[edge contentView] setRecording:recording];

    [formatPopUp setEnabled:state == RecordingFrameIdle];
    // The size can be typed in until recording starts; then the bar shows
    // the countdown, the time, or that it is saving
    [widthField setHidden:state != RecordingFrameIdle];
    [timesLabel setHidden:state != RecordingFrameIdle];
    [heightField setHidden:state != RecordingFrameIdle];
    [infoLabel setHidden:state == RecordingFrameIdle];
    [cancelButton setEnabled:state != RecordingFrameSaving];
    [recordButton setEnabled:state != RecordingFrameSaving];
    [recordButton setTitle:state == RecordingFrameIdle ? NSLocalizedString(@"Record", @"")
                                                       : NSLocalizedString(@"Stop", @"")];
    if (state == RecordingFrameSaving) {
        [spinner startAnimation:self];
        NSRect f = [infoLabel frame];
        f.origin.x = NSMaxX([spinner frame]) + METRICS_SPACE_8;
        [infoLabel setFrame:f];
        [infoLabel setStringValue:NSLocalizedString(@"Saving...", @"")];
    } else {
        [spinner stopAnimation:self];
        NSRect f = [infoLabel frame];
        f.origin.x = NSMinX([spinner frame]);
        [infoLabel setFrame:f];
    }
    if (state == RecordingFrameIdle)
        [self setArea:area];
}

- (void)showCountdown:(int)seconds
{
    [infoLabel setStringValue:[NSString stringWithFormat:
        NSLocalizedString(@"Recording in %d...", @""), seconds]];
}

- (void)showElapsedTime:(NSTimeInterval)seconds
{
    int s = (int)seconds;
    [infoLabel setStringValue:[NSString stringWithFormat:@"%d:%02d", s / 60, s % 60]];
}

- (BOOL)isEditingSize
{
    id responder = [bar firstResponder];
    return [responder isKindOfClass:[NSText class]]
        && ([responder delegate] == (id)widthField || [responder delegate] == (id)heightField);
}

/* The top left corner stays where it is, as when a window is resized. */
- (void)sizeEdited:(id)sender
{
    if (state != RecordingFrameIdle)
        return;
    NSRect screen = [self screenFrame];
    CGFloat width = MAX(kMinimumSide, MIN([widthField intValue], NSWidth(screen)));
    CGFloat height = MAX(kMinimumSide, MIN([heightField intValue], NSHeight(screen)));
    NSRect sized = NSMakeRect(NSMinX(area), NSMaxY(area) - height, width, height);
    [self setArea:[self areaOnScreen:sized]];
}

- (void)formatChosen:(id)sender
{
    [delegate recordingFrame:self didChooseFormat:(ScreenRecordingFormat)[formatPopUp indexOfSelectedItem]];
}

- (void)recordOrStop:(id)sender
{
    if (state == RecordingFrameIdle)
        [delegate recordingFrameRecord:self];
    else
        [delegate recordingFrameStop:self];
}

- (void)cancel:(id)sender
{
    [delegate recordingFrameCancel:self];
}

@end
