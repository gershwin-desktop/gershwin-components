/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGScreenshotView.h"
#import "AGColors.h"
#import "AppearanceMetrics.h"

static const CGFloat kAGScreenshotRadius = 10.0;
static const CGFloat kAGScreenshotSpinnerSide = 16.0;
static const CGFloat kAGScreenshotMaxHeight = 420.0;
/* Letterbox height per point of width: 16/9, inverted below. */
static const CGFloat kAGScreenshotWide = 16.0;
static const CGFloat kAGScreenshotTall = 9.0;
static const CGFloat kAGScreenshotBorder = 1.0;

/* One style for the fallback line: centered, 13 pt, the theme's grey. */
static NSDictionary *AGScreenshotMessageAttributes(void)
{
  static NSDictionary *attributes = nil;
  if (attributes == nil)
    {
      NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
      [style setAlignment:NSCenterTextAlignment];
      attributes = @{
        NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_13,
        NSForegroundColorAttributeName : [NSColor disabledControlTextColor],
        NSParagraphStyleAttributeName : style
      };
    }
  return attributes;
}

/* The largest rect of the given aspect that fits inside outer, centered.
 * Both origins are computed from the outer rect, so this is right in a
 * flipped view and in an upright one alike. */
static NSRect AGScreenshotFitRect(NSSize size, NSRect outer)
{
  if (size.width <= 0.0 || size.height <= 0.0)
    return NSZeroRect;

  CGFloat scale = MIN(NSWidth(outer) / size.width, NSHeight(outer) / size.height);
  NSSize fitted = NSMakeSize(size.width * scale, size.height * scale);
  return NSMakeRect(NSMinX(outer) + (NSWidth(outer) - fitted.width) / 2.0,
                    NSMinY(outer) + (NSHeight(outer) - fitted.height) / 2.0,
                    fitted.width, fitted.height);
}

@implementation AGScreenshotView
{
  NSProgressIndicator *_spinner;
}

+ (CGFloat)heightForWidth:(CGFloat)width
{
  if (width <= 0.0)
    return 0.0;
  return MIN(width * kAGScreenshotTall / kAGScreenshotWide, kAGScreenshotMaxHeight);
}

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _state = AGScreenshotStateLoading;

      /* An explicit size: -sizeToFit answers zero for a spinning indicator
       * under the Eau theme, which left the spinner invisible. */
      _spinner = [[NSProgressIndicator alloc]
          initWithFrame:NSMakeRect(0.0, 0.0, kAGScreenshotSpinnerSide, kAGScreenshotSpinnerSide)];
      [_spinner setStyle:NSProgressIndicatorSpinningStyle];
      [_spinner setControlSize:NSSmallControlSize];
      [_spinner setIndeterminate:YES];
      [_spinner setBezeled:NO];
      [_spinner setHidden:YES];
      [self addSubview:_spinner];
      [self centerSpinner];
    }
  return self;
}

#pragma mark - State

- (void)setState:(AGScreenshotState)state
{
  if (_state == state)
    return;
  _state = state;
  [self updateSpinner];
  [self setNeedsDisplay:YES];
}

- (void)setImage:(NSImage *)image
{
  _image = image;
  if (image != nil)
    self.state = AGScreenshotStateLoaded;
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  /* The spinner animates only while it can be seen; a detail page that
   * scrolled away must not keep a timer alive in the window's timers. */
  [self updateSpinner];
}

/* Start or stop the spinner for the current state and window. */
- (void)updateSpinner
{
  BOOL spinning = (_state == AGScreenshotStateLoading && [self window] != nil);
  if (spinning)
    [_spinner startAnimation:nil];
  else
    [_spinner stopAnimation:nil];
  [_spinner setHidden:!spinning];
}

#pragma mark - Geometry

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self centerSpinner];
}

- (void)setFrameSize:(NSSize)size
{
  [super setFrameSize:size];
  [self centerSpinner];
}

- (void)centerSpinner
{
  if (_spinner == nil)
    return;
  NSSize size = [_spinner frame].size;
  NSRect bounds = [self bounds];
  [_spinner setFrame:NSMakeRect(NSMidX(bounds) - size.width / 2.0,
                                NSMidY(bounds) - size.height / 2.0,
                                size.width, size.height)];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
  (void)dirtyRect;
  NSRect bounds = [self bounds];
  if (NSIsEmptyRect(bounds))
    return;

  NSBezierPath *frame = [NSBezierPath
      bezierPathWithRoundedRect:NSInsetRect(bounds, kAGScreenshotBorder / 2.0,
                                               kAGScreenshotBorder / 2.0)
                        xRadius:kAGScreenshotRadius
                        yRadius:kAGScreenshotRadius];

  [AGScreenshotLetterboxColor() setFill];
  [frame fill];

  if (_state == AGScreenshotStateLoaded && _image != nil)
    {
      NSRect imageRect = AGScreenshotFitRect([_image size], bounds);
      if (!NSIsEmptyRect(imageRect))
        {
          NSGraphicsContext *context = [NSGraphicsContext currentContext];
          NSImageInterpolation saved = [context imageInterpolation];
          [context setImageInterpolation:NSImageInterpolationHigh];
          [NSGraphicsContext saveGraphicsState];
          [frame addClip];
          [_image drawInRect:imageRect
                    fromRect:NSZeroRect
                   operation:NSCompositeSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
          [NSGraphicsContext restoreGraphicsState];
          [context setImageInterpolation:saved];
        }
    }
  else if (_state == AGScreenshotStateFailed)
    {
      /* The failure text sits on the mount, so it needs the mount's width
       * to wrap and its height to stay a single centered line. */
      NSRect textRect = NSInsetRect(bounds, 16.0, 0.0);
      NSString *message = NSLocalizedString(@"Screenshot unavailable", @"");
      NSRect measured = [message
          boundingRectWithSize:NSMakeSize(NSWidth(textRect), NSHeight(textRect))
                       options:NSStringDrawingUsesLineFragmentOrigin
                    attributes:AGScreenshotMessageAttributes()];
      NSRect line = NSMakeRect(NSMinX(textRect),
                               NSMidY(textRect) - NSHeight(measured) / 2.0,
                               NSWidth(textRect), NSHeight(measured));
      [message drawInRect:line withAttributes:AGScreenshotMessageAttributes()];
    }

  [AGCardBorderColor() setStroke];
  [frame setLineWidth:kAGScreenshotBorder];
  [frame stroke];
}

@end
