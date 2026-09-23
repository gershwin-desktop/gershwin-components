/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWProgressWindowController.h"
#import "AppearanceMetrics.h"

static const float kWinWidth = METRICS_WIN_MIN_WIDTH;
static const float kCollapsedHeight = 150.0;
static const float kPhasesBoxHeight = 200.0;
static const float kExpandedHeight = 380.0;
static const float kPhaseRowHeight = 22.0;
static const float kItemRowHeight = 20.0;
static const float kIconSmall = 16.0;

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
  [content addSubview:_headlineField];

  _progressBar = [[NSProgressIndicator alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, NSMinY([_headlineField frame]) - METRICS_SPACE_16 - 20.0,
               contentRight - METRICS_CONTENT_SIDE_MARGIN, 20.0)];
  [_progressBar setStyle:NSProgressIndicatorStyleBar];
  [_progressBar setIndeterminate:NO];
  [_progressBar setMinValue:0.0];
  [_progressBar setMaxValue:1.0];
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
  [content addSubview:_statusField];

  _detailsButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(METRICS_CONTENT_SIDE_MARGIN, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_detailsButton setTitle:@"Details"];
  [_detailsButton setTarget:self];
  [_detailsButton setAction:@selector(detailsClicked:)];
  [content addSubview:_detailsButton];

  _stopButton = [[NSButton alloc] initWithFrame:
    NSMakeRect(contentRight - METRICS_BUTTON_MIN_WIDTH, METRICS_CONTENT_BOTTOM_MARGIN,
               METRICS_BUTTON_MIN_WIDTH, METRICS_BUTTON_HEIGHT)];
  [_stopButton setTitle:@"Stop"];
  [_stopButton setTarget:self];
  [_stopButton setAction:@selector(stopClicked:)];
  [content addSubview:_stopButton];

  NSRect boxFrame = NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                                METRICS_CONTENT_BOTTOM_MARGIN + METRICS_BUTTON_HEIGHT + METRICS_SPACE_16,
                                contentRight - METRICS_CONTENT_SIDE_MARGIN, kPhasesBoxHeight);
  _phasesScroll = [[NSScrollView alloc] initWithFrame:boxFrame];
  [_phasesScroll setHasVerticalScroller:YES];
  [_phasesScroll setBorderType:NSBezelBorder];
  [_phasesScroll setHidden:YES];
  _phasesContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(boxFrame), kPhasesBoxHeight)];
  [_phasesScroll setDocumentView:_phasesContainer];
  [content addSubview:_phasesScroll];
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
  _detailsVisible = !_detailsVisible;
  [_detailsButton setTitle:_detailsVisible ? @"Hide Details" : @"Details"];

  float newHeight = _detailsVisible ? kExpandedHeight : kCollapsedHeight;
  float contentRight = kWinWidth - METRICS_CONTENT_SIDE_MARGIN;

  [_headlineField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
    newHeight - METRICS_CONTENT_TOP_MARGIN - 20.0, contentRight - METRICS_CONTENT_SIDE_MARGIN, 20.0)];
  [_progressBar setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
    NSMinY([_headlineField frame]) - METRICS_SPACE_16 - 20.0, contentRight - METRICS_CONTENT_SIDE_MARGIN, 20.0)];
  [_statusField setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
    NSMinY([_progressBar frame]) - METRICS_SPACE_8 - 16.0, contentRight - METRICS_CONTENT_SIDE_MARGIN, 16.0)];

  [_phasesScroll setHidden:!_detailsVisible];

  // -setFrame: takes a FRAME rect (screen frame, titlebar included), not the
  // CONTENT rect newHeight is expressed in - passing newHeight straight
  // through made the window's actual content area a titlebar-height (22pt)
  // short of what every field above was just laid out for. Converting
  // through -frameRectForContentRect: gets the right frame height regardless
  // of the window's actual titlebar height; anchoring on the OLD frame's top
  // edge (NSMaxY), not a hand-computed delta, is what keeps that edge fixed
  // on screen while the window grows downward to reveal the details box -
  // the previous delta math left the window's reported height unchanged
  // entirely on a non-resizable window (the WM's fixed-size hints clamped
  // it), which is also fixed below by making the window resizable.
  NSWindow *window = [self window];
  NSRect desiredContentRect = NSMakeRect(0, 0, kWinWidth, newHeight);
  NSRect desiredFrameRect = [window frameRectForContentRect:desiredContentRect];
  float frameHeight = NSHeight(desiredFrameRect);

  NSRect currentFrame = [window frame];
  NSRect newFrame = NSMakeRect(currentFrame.origin.x,
                                NSMaxY(currentFrame) - frameHeight,
                                kWinWidth, frameHeight);
  [window setFrame:newFrame display:YES animate:NO];
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
