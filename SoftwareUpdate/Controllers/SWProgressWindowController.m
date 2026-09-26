/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWProgressWindowController.h"
#import "AppearanceMetrics.h"

static const float kWinWidth = METRICS_WIN_MIN_WIDTH;
// Built up the same way the layout itself is: header text block, then the
// details disclosure row, then (when expanded) the phases box, then the
// footer button row - so kCollapsedHeight/kExpandedHeight always match what
// -buildContent actually lays out instead of being independent guesses.
static const float kHeaderHeight = METRICS_CONTENT_TOP_MARGIN + 20.0 + METRICS_SPACE_16
                                  + 20.0 + METRICS_SPACE_8 + 16.0;
static const float kDetailsRowHeight = METRICS_BUTTON_HEIGHT;
static const float kFooterHeight = METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT;
static const float kPhasesBoxHeight = 200.0;
static const float kCollapsedHeight = kHeaderHeight + METRICS_SPACE_16 + kDetailsRowHeight
                                     + METRICS_SPACE_16 + kFooterHeight;
static const float kExpandedHeight = kHeaderHeight + METRICS_SPACE_16 + kDetailsRowHeight
                                    + METRICS_SPACE_16 + kPhasesBoxHeight
                                    + METRICS_SPACE_16 + kFooterHeight;
// The Eau theme's disclosure triangle is drawn at 40% of its button's frame
// (Eau+Button.m), so the stock 13x13 GNUstep disclosure button renders a
// ~5pt glyph - much smaller and fainter than the handoff mockup's bold,
// nearly edge-to-edge triangle. Sizing the button up is the only lever this
// theme call exposes for that.
static const float kDisclosureSide = 24.0;
static const float kPhaseRowHeight = 22.0;
static const float kItemRowHeight = 20.0;
static const float kIconSmall = 16.0;

// GNUstep's NSView -alphaValue is a documented no-op (there is no layer
// backing yet), so fading the phases box in/out cannot be done by animating
// a view's own opacity. NSImage compositing DOES support a real alpha
// fraction, though (-drawInRect:fromRect:operation:fraction:), so this view
// fakes the fade by drawing a snapshot of the box's content at a controllable
// fraction instead of the box itself.
@interface GWFadeOverlayView : NSView
{
  NSImage *_fadeImage;
  CGFloat _fadeFraction;
}
- (void)setFadeImage:(NSImage *)image;
- (void)setFadeFraction:(CGFloat)fraction;
@end

@implementation GWFadeOverlayView
- (void)setFadeImage:(NSImage *)image
{
  _fadeImage = image;
}
- (void)setFadeFraction:(CGFloat)fraction
{
  _fadeFraction = fraction;
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect
{
  if (_fadeFraction <= 0.0) return;
  [_fadeImage drawInRect:[self bounds]
                 fromRect:NSMakeRect(0, 0, [_fadeImage size].width, [_fadeImage size].height)
                operation:NSCompositeSourceOver
                 fraction:_fadeFraction];
}
@end

@interface SWProgressWindowController ()
{
  NSTextField *_headlineField;
  NSProgressIndicator *_progressBar;
  NSTextField *_statusField;
  NSButton *_detailsButton;
  NSButton *_stopButton;
  NSScrollView *_phasesScroll;
  NSView *_phasesContainer;
  NSMutableArray<SWProgressPhase *> *_phases;
  BOOL _detailsVisible;
  NSTimer *_detailsAnimTimer;
  GWFadeOverlayView *_boxFadeOverlay;
}
@end

@implementation SWProgressWindowController

@synthesize delegate = _delegate;

- (instancetype)init
{
  NSRect frame = NSMakeRect(0, 0, kWinWidth, kCollapsedHeight);
  NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  self = [super initWithWindow:window];
  if (self) {
    [window setTitle:@"Software Update"];
    [window center];
    [window setReleasedWhenClosed:NO];
    _phases = [NSMutableArray array];
    [self buildContent];
  }
  return self;
}

- (void)buildContent
{
  NSView *content = [[self window] contentView];
  float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

  _headlineField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, kCollapsedHeight - METRICS_CONTENT_TOP_MARGIN - 20.0,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, 20.0)];
  [_headlineField setStringValue:@"Updating…"];
  [_headlineField setFont:METRICS_FONT_SYSTEM_BOLD_13];
  [_headlineField setBezeled:NO];
  [_headlineField setDrawsBackground:NO];
  [_headlineField setEditable:NO];
  [_headlineField setSelectable:NO];
  // Pin to the window's top edge (fixed local y grows automatically as the
  // content view's height changes) so this stays visually still while the
  // disclosure animation grows/shrinks the window from the bottom.
  [_headlineField setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_headlineField];

  _progressBar = [[NSProgressIndicator alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSMinY([_headlineField frame]) - METRICS_SPACE_16 - 20.0,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, 20.0)];
  [_progressBar setStyle:NSProgressIndicatorStyleBar];
  [_progressBar setIndeterminate:NO];
  [_progressBar setMinValue:0.0];
  [_progressBar setMaxValue:1.0];
  [_progressBar setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_progressBar];

  _statusField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSMinY([_progressBar frame]) - METRICS_SPACE_8 - 16.0,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, 16.0)];
  [_statusField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
  [_statusField setTextColor:[NSColor disabledControlTextColor]];
  [_statusField setBezeled:NO];
  [_statusField setDrawsBackground:NO];
  [_statusField setEditable:NO];
  [_statusField setSelectable:NO];
  [_statusField setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_statusField];

  // The handoff mockup uses a plain disclosure triangle next to a static
  // "Details" label (the triangle flips direction, the label never changes),
  // not a bordered push button whose title text swaps between "Details" and
  // "Hide Details" - GNUstep has this natively (NSDisclosureBezelStyle +
  // NSPushOnPushOffButton; the Eau theme already draws the triangle open or
  // closed from the button's own on/off state), so use that instead of
  // hand-rolling the look with a regular button. It sits directly below the
  // status line and above the (revealed/hidden) box, matching the mockup -
  // not down at the bottom sharing a row with Stop, which is where the box
  // ended up appearing BELOW this row instead of above it.
  float detailsRowY = NSMinY([_statusField frame]) - METRICS_SPACE_16 - kDetailsRowHeight;
  _detailsButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
               detailsRowY + (kDetailsRowHeight - kDisclosureSide) / 2.0,
               kDisclosureSide, kDisclosureSide)];
  [_detailsButton setBezelStyle:NSDisclosureBezelStyle];
  [_detailsButton setButtonType:NSPushOnPushOffButton];
  [_detailsButton setTitle:@""];
  [_detailsButton setTarget:self];
  [_detailsButton setAction:@selector(detailsClicked:)];
  [_detailsButton setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_detailsButton];

  NSTextField *detailsLabel = [[NSTextField alloc] initWithFrame:
    NSMakeRect(NSMaxX([_detailsButton frame]) + METRICS_SPACE_8, detailsRowY,
               100.0, kDetailsRowHeight)];
  [detailsLabel setStringValue:@"Details"];
  [detailsLabel setFont:METRICS_FONT_SYSTEM_REGULAR_13];
  [detailsLabel setBezeled:NO];
  [detailsLabel setDrawsBackground:NO];
  [detailsLabel setEditable:NO];
  [detailsLabel setSelectable:NO];
  [detailsLabel setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:detailsLabel];

  _stopButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_stopButton setTitle:@"Stop"];
  [_stopButton setTarget:self];
  [_stopButton setAction:@selector(stopClicked:)];
  [content addSubview:_stopButton];

  // Directly below the details row (revealed/hidden, not repositioned, as
  // the window grows/shrinks) - pinned to the top the same way, so its
  // distance below the details row stays constant at any window height,
  // including while the disclosure animation is mid-flight.
  NSRect boxFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                detailsRowY - METRICS_SPACE_16 - kPhasesBoxHeight,
                                contentRight - METRICS_CONTENT_SIDE_MARGIN, kPhasesBoxHeight);
  _phasesScroll = [[NSScrollView alloc] initWithFrame:boxFrame];
  [_phasesScroll setHasVerticalScroller:YES];
  [_phasesScroll setBorderType:NSBezelBorder];
  [_phasesScroll setHidden:YES];
  [_phasesScroll setAutoresizingMask:NSViewMinYMargin];
  _phasesContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(boxFrame), kPhasesBoxHeight)];
  [_phasesScroll setDocumentView:_phasesContainer];
  [content addSubview:_phasesScroll];

  // Sits exactly over the box and is only ever shown mid-fade (see
  // -detailsClicked:); hidden and empty the rest of the time. Also pinned to
  // the top so it tracks the box's own position through the resize.
  _boxFadeOverlay = [[GWFadeOverlayView alloc] initWithFrame:boxFrame];
  [_boxFadeOverlay setHidden:YES];
  [_boxFadeOverlay setAutoresizingMask:NSViewMinYMargin];
  [content addSubview:_boxFadeOverlay];
}

#pragma mark - Public API

- (void)setPhases:(NSArray<SWProgressPhase *> *)phases
{
  _phases = [phases mutableCopy];
  [self reloadPhasesBox];
}

- (SWProgressPhase *)phaseWithIdentifier:(NSString *)identifier
{
  for (SWProgressPhase *phase in _phases) {
    if ([[phase identifier] isEqualToString:identifier]) return phase;
  }
  return nil;
}

- (void)beginPhaseWithIdentifier:(NSString *)identifier headline:(NSString *)headline
{
  for (SWProgressPhase *phase in _phases) {
    if ([[phase identifier] isEqualToString:identifier]) {
      [phase setStatus:SWProgressItemStatusRunning];
    } else if ([phase status] == SWProgressItemStatusRunning) {
      [phase setStatus:SWProgressItemStatusDone];
    }
  }
  [_headlineField setStringValue:headline];
  [self reloadPhasesBox];
}

- (void)finishPhaseWithIdentifier:(NSString *)identifier
{
  SWProgressPhase *phase = [self phaseWithIdentifier:identifier];
  [phase setStatus:SWProgressItemStatusDone];
  for (SWProgressItem *item in [phase items]) {
    [item setStatus:SWProgressItemStatusDone];
  }
  [self reloadPhasesBox];
}

- (void)beginItemAtIndex:(NSUInteger)index
       inPhaseWithIdentifier:(NSString *)identifier
                trailingText:(NSString *)trailingText
{
  SWProgressPhase *phase = [self phaseWithIdentifier:identifier];
  NSArray<SWProgressItem *> *items = [phase items];
  for (NSUInteger i = 0; i < [items count]; i++) {
    SWProgressItem *item = items[i];
    if (i < index) {
      if ([item status] != SWProgressItemStatusFailed) [item setStatus:SWProgressItemStatusDone];
    } else if (i == index) {
      [item setStatus:SWProgressItemStatusRunning];
      [item setTrailingText:trailingText];
    } else {
      [item setStatus:SWProgressItemStatusPending];
    }
  }
  [self reloadPhasesBox];
}

- (void)setStatusText:(NSString *)text
{
  [_statusField setStringValue:text ?: @""];
}

- (void)setOverallProgress:(float)fraction
{
  [_progressBar setDoubleValue:fraction];
}

#pragma mark - Details disclosure

- (void)detailsClicked:(id)sender
{
  // NSPushOnPushOffButton already flipped [_detailsButton state] before this
  // action fired, which is what drives the Eau theme's arrow direction - so
  // _detailsVisible only needs to track it for the resize math below.
  _detailsVisible = !_detailsVisible;

  float targetContentHeight = _detailsVisible ? kExpandedHeight : kCollapsedHeight;

  // The details box's own frame never depends on newHeight (it sits at a
  // fixed distance from the button row below it - see buildContent), so
  // revealing/hiding it is purely a visibility flip. Show it before growing
  // so the roll-down animation clips it into view; keep it visible through
  // a shrink so it clips OUT of view, only hiding it once fully collapsed
  // (below), matching the roller-blind reveal used for WindowShade.
  // Real views can't fade in GNUstep (-alphaValue is a documented no-op, no
  // layer backing yet), so a genuine fade needs NSImage's fraction-based
  // compositing instead - capture the box as a snapshot, hide the real
  // (interactive) one, and cross-fade the snapshot's opacity over the same
  // ticks that grow/shrink the window, so it rolls into view AND fades in
  // at once rather than just one or the other.
  if (_detailsVisible) {
    [_phasesScroll setHidden:NO];
    NSRect boxBounds = [_phasesScroll bounds];
    NSBitmapImageRep *rep = [_phasesScroll bitmapImageRepForCachingDisplayInRect:boxBounds];
    [_phasesScroll cacheDisplayInRect:boxBounds toBitmapImageRep:rep];
    NSImage *snapshot = [[NSImage alloc] initWithSize:[rep size]];
    [snapshot addRepresentation:rep];
    [_phasesScroll setHidden:YES];
    [_boxFadeOverlay setFadeImage:snapshot];
    [_boxFadeOverlay setFadeFraction:0.0];
    [_boxFadeOverlay setHidden:NO];
  } else {
    NSRect boxBounds = [_phasesScroll bounds];
    NSBitmapImageRep *rep = [_phasesScroll bitmapImageRepForCachingDisplayInRect:boxBounds];
    [_phasesScroll cacheDisplayInRect:boxBounds toBitmapImageRep:rep];
    NSImage *snapshot = [[NSImage alloc] initWithSize:[rep size]];
    [snapshot addRepresentation:rep];
    [_phasesScroll setHidden:YES];
    [_boxFadeOverlay setFadeImage:snapshot];
    [_boxFadeOverlay setFadeFraction:1.0];
    [_boxFadeOverlay setHidden:NO];
  }

  // -setFrame: takes a FRAME rect (screen frame, titlebar included), not a
  // content rect - convert through -frameRectForContentRect: so the result
  // is correct regardless of titlebar height AND of the display's current
  // backing scale factor (a hardcoded content width/height here would only
  // match the window's actual on-screen size at scale 1.0).
  NSWindow *window = [self window];
  NSRect desiredContentRect = NSMakeRect(0, 0, kWinWidth, targetContentHeight);
  NSRect desiredFrameRect = [window frameRectForContentRect:desiredContentRect];
  float toFrameHeight = NSHeight(desiredFrameRect);

  NSRect currentFrame = [window frame];
  float fromFrameHeight = NSHeight(currentFrame);
  float fixedWidth = NSWidth(currentFrame);   // never changes: only height animates
  float fixedX = currentFrame.origin.x;
  float topY = NSMaxY(currentFrame);          // titlebar edge to hold fixed

  if (fromFrameHeight == toFrameHeight) return;

  // Roller-blind animation, same easing/timing as the WindowShade roll-up in
  // gershwin-windowmanager's XCBFrame -animateFrameHeightFrom:toHeight: -
  // 60fps timer, 0.22s, quadratic ease-out - so a details disclosure feels
  // like the same physical motion as the window manager's own shade.
  if (_detailsAnimTimer) {
    [_detailsAnimTimer invalidate];
    _detailsAnimTimer = nil;
  }

  __weak SWProgressWindowController *weakSelf = self;
  NSTimeInterval duration = 0.22;
  NSDate *startDate = [NSDate date];
  BOOL collapsing = !_detailsVisible;

  NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                          repeats:YES
                                            block:^(NSTimer *stepTimer) {
    SWProgressWindowController *strongSelf = weakSelf;
    if (!strongSelf) {
      [stepTimer invalidate];
      return;
    }

    NSTimeInterval elapsed = -1.0 * [startDate timeIntervalSinceNow];
    CGFloat progress = elapsed / duration;
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;
    BOOL done = progress >= 1.0;
    if (!done)
      progress = 1.0 - (1.0 - progress) * (1.0 - progress);   // ease-out

    float h = fromFrameHeight + (toFrameHeight - fromFrameHeight) * progress;
    NSRect stepFrame = NSMakeRect(fixedX, topY - h, fixedWidth, h);
    [strongSelf->_boxFadeOverlay setFadeFraction:collapsing ? (1.0 - progress) : progress];
    [[strongSelf window] setFrame:stepFrame display:YES animate:NO];

    if (done) {
      [stepTimer invalidate];
      strongSelf->_detailsAnimTimer = nil;
      NSRect finalFrame = NSMakeRect(fixedX, topY - toFrameHeight, fixedWidth, toFrameHeight);
      [[strongSelf window] setFrame:finalFrame display:YES animate:NO];
      [strongSelf->_boxFadeOverlay setHidden:YES];
      if (!collapsing)
        [strongSelf->_phasesScroll setHidden:NO];
    }
  }];

  _detailsAnimTimer = timer;
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
}

- (void)stopClicked:(id)sender
{
  [[self delegate] progressWindowControllerDidClickStop:self];
}

#pragma mark - Phases box rendering

- (NSImage *)imageForStatus:(SWProgressItemStatus)status
{
  switch (status) {
    case SWProgressItemStatusDone: return [NSImage imageNamed:@"StatusDone"];
    case SWProgressItemStatusRunning: return [NSImage imageNamed:@"StatusRunning"];
    case SWProgressItemStatusFailed: return [NSImage imageNamed:@"StatusWarning"];
    case SWProgressItemStatusSkipped: return [NSImage imageNamed:@"StatusSkipped"];
    case SWProgressItemStatusPending:
    default: return [NSImage imageNamed:@"StatusPending"];
  }
}

- (void)reloadPhasesBox
{
  for (NSView *subview in [[_phasesContainer subviews] copy]) {
    [subview removeFromSuperview];
  }

  // The content view's bounds already exclude the vertical scroller's width;
  // using the scroll view's own (wider) bounds instead let trailing-text
  // fields run under the scroller and get clipped there.
  float width = NSWidth([[_phasesScroll contentView] bounds]);
  float y = 0; // building bottom-up in a coordinate space we will flip at the end
  NSMutableArray *rows = [NSMutableArray array]; // (view, height) built top-down conceptually

  // Build phase rows in order (top of the list = first phase), each
  // followed immediately by its items when it is the running phase.
  for (SWProgressPhase *phase in _phases) {
    [rows addObject:@{@"view": [self rowViewWithIcon:[self imageForStatus:[phase status]]
                                                 title:[phase title]
                                          trailingText:@""
                                                 indent:0.0
                                                   bold:YES
                                                 width:width],
                       @"height": @(kPhaseRowHeight)}];
    if ([phase status] == SWProgressItemStatusRunning) {
      for (SWProgressItem *item in [phase items]) {
        [rows addObject:@{@"view": [self rowViewWithIcon:[self imageForStatus:[item status]]
                                                     title:[item title]
                                              trailingText:[item trailingText] ?: @""
                                                    indent:METRICS_CONTENT_SIDE_MARGIN
                                                      bold:NO
                                                    width:width],
                           @"height": @(kItemRowHeight)}];
      }
    }
  }

  float totalHeight = 0;
  for (NSDictionary *row in rows) totalHeight += [row[@"height"] floatValue];
  float containerHeight = MAX(totalHeight, NSHeight([_phasesScroll bounds]));
  [_phasesContainer setFrame:NSMakeRect(0, 0, width, containerHeight)];

  // Place rows top-down: the first row's top edge is the container's top edge.
  y = containerHeight;
  for (NSDictionary *row in rows) {
    float h = [row[@"height"] floatValue];
    NSView *view = row[@"view"];
    [view setFrame:NSMakeRect(0, y - h, width, h)];
    [view setAutoresizingMask:NSViewWidthSizable];
    [_phasesContainer addSubview:view];
    y -= h;
  }
}

- (NSView *)rowViewWithIcon:(NSImage *)icon
                       title:(NSString *)title
                trailingText:(NSString *)trailingText
                      indent:(float)indent
                        bold:(BOOL)bold
                       width:(float)width
{
  NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
  float titleLeft = METRICS_SPACE_8 + indent + kIconSmall + METRICS_SPACE_8;

  NSImageView *iconView = [[NSImageView alloc] initWithFrame:
    NSMakeRect(METRICS_SPACE_8 + indent, 2.0, kIconSmall, kIconSmall)];
  [iconView setImage:icon];
  [row addSubview:iconView];

  // The trailing field, if any, is right-anchored within this row's own
  // width; the title field fills whatever is left of it, so neither one
  // depends on a guessed absolute width that could run under the scroller.
  float trailingWidth = [trailingText length] > 0 ? 110.0 : 0.0;
  float titleWidth = width - titleLeft - METRICS_SPACE_8 - trailingWidth
                    - (trailingWidth > 0 ? METRICS_SPACE_8 : 0.0);

  NSTextField *titleField = [[NSTextField alloc] initWithFrame:
    NSMakeRect(titleLeft, 0.0, MAX(titleWidth, 40.0), 18.0)];
  [titleField setStringValue:title ?: @""];
  [titleField setFont:bold ? METRICS_FONT_SYSTEM_BOLD_11 : METRICS_FONT_SYSTEM_REGULAR_11];
  [[titleField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
  [titleField setBezeled:NO];
  [titleField setDrawsBackground:NO];
  [titleField setEditable:NO];
  [titleField setSelectable:NO];
  [row addSubview:titleField];

  if (trailingWidth > 0) {
    NSTextField *trailingField = [[NSTextField alloc] initWithFrame:
      NSMakeRect(width - METRICS_SPACE_8 - trailingWidth, 0.0, trailingWidth, 18.0)];
    [trailingField setStringValue:trailingText];
    [trailingField setFont:METRICS_FONT_SYSTEM_REGULAR_11];
    [trailingField setTextColor:[NSColor disabledControlTextColor]];
    [trailingField setAlignment:NSRightTextAlignment];
    [[trailingField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [trailingField setBezeled:NO];
    [trailingField setDrawsBackground:NO];
    [trailingField setEditable:NO];
    [trailingField setSelectable:NO];
    [row addSubview:trailingField];
  }

  return row;
}

@end
