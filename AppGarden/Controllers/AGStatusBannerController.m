/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGStatusBannerController.h"
#import "AGColors.h"
#import "AppearanceMetrics.h"

static const CGFloat kAGBannerHeight = 32.0;

/* A plain view with the banner tint; kept as a class so the tint survives
   the theme's window background repaint. */
@interface AGStatusBannerView : NSView
@end

@implementation AGStatusBannerView

- (void)drawRect:(NSRect)dirtyRect
{
  [AGBannerBackgroundColor() set];
  NSRectFill(dirtyRect);
  [[NSColor gridColor] set];
  NSRectFill(NSMakeRect(0.0, 0.0, NSWidth([self bounds]), 1.0));
}

@end

@implementation AGStatusBannerController
{
  AGStatusBannerView *_view;
  NSTextField *_label;
  NSButton *_retryButton;
}

@synthesize target = _target;
@synthesize action = _action;

+ (CGFloat)height
{
  return kAGBannerHeight;
}

- (instancetype)init
{
  self = [super init];
  if (self != nil)
    {
      _view = [[AGStatusBannerView alloc]
          initWithFrame:NSMakeRect(0.0, 0.0, 600.0, kAGBannerHeight)];
      [_view setAutoresizingMask:NSViewWidthSizable];

      _retryButton = [[NSButton alloc] initWithFrame:NSZeroRect];
      [_retryButton setBezelStyle:NSRoundedBezelStyle];
      [_retryButton setTitle:NSLocalizedString(@"Retry", @"")];
      [_retryButton setFont:METRICS_FONT_SYSTEM_REGULAR_13];
      [_retryButton setTarget:self];
      [_retryButton setAction:@selector(retryClicked:)];
      [_retryButton setAutoresizingMask:NSViewMinXMargin];
      [_view addSubview:_retryButton];

      _label = [[NSTextField alloc] initWithFrame:NSZeroRect];
      [_label setEditable:NO];
      [_label setSelectable:NO];
      [_label setBordered:NO];
      [_label setBezeled:NO];
      [_label setDrawsBackground:NO];
      [_label setFont:METRICS_FONT_SYSTEM_REGULAR_13];
      [[_label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
      [_label setAutoresizingMask:NSViewWidthSizable];
      [_view addSubview:_label];

      [self layoutForWidth:NSWidth([_view frame])];
    }
  return self;
}

- (void)layoutForWidth:(CGFloat)width
{
  CGFloat buttonHeight = METRICS_BUTTON_HEIGHT;
  NSRect buttonFrame = NSMakeRect(width - METRICS_CONTENT_SIDE_MARGIN - METRICS_BUTTON_MIN_WIDTH,
                                  floor((kAGBannerHeight - buttonHeight) / 2.0),
                                  METRICS_BUTTON_MIN_WIDTH, buttonHeight);
  [_retryButton setFrame:buttonFrame];

  CGFloat labelHeight = 17.0;
  [_label setFrame:NSMakeRect(METRICS_CONTENT_SIDE_MARGIN,
                              floor((kAGBannerHeight - labelHeight) / 2.0),
                              NSMinX(buttonFrame) - METRICS_SPACE_12 - METRICS_CONTENT_SIDE_MARGIN,
                              labelHeight)];
}

- (NSView *)view
{
  return _view;
}

- (NSString *)message
{
  return [_label stringValue];
}

- (void)setMessage:(NSString *)message
{
  [_label setStringValue:(message != nil) ? message : @""];
  [_label setToolTip:message];
}

- (void)retryClicked:(id)sender
{
  (void)sender;
  if (_target != nil && _action != NULL)
    [NSApp sendAction:_action to:_target from:self];
}

@end
