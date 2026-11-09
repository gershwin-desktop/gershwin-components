/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGAppCardView.h"
#import "AGColors.h"
#import "AppearanceMetrics.h"
#import "AGApp.h"
#import "AGInstallButton.h"
#import "AGPlaceholderIcon.h"

static const CGFloat kAGCardWidth = 160.0;
static const CGFloat kAGCardHeight = 176.0;
static const CGFloat kAGCardCornerRadius = 10.0;
static const CGFloat kAGIconSide = 48.0;
/* Card title to summary; AppearanceMetrics has no 4-point step and the
 * design calls for exactly this, so the number lives here once. */
static const CGFloat kAGNameSummaryGap = 4.0;

#pragma mark - Text attributes

/*
 * Measured and drawn from the same dictionaries: the layout a measurement
 * produces and the layout the draw produces must agree, or a truncated
 * string would still overflow. The caches are plain statics because every
 * caller is on the main thread.
 */
static NSDictionary *AGNameAttributes(void)
{
  static NSDictionary *attributes = nil;
  if (attributes == nil)
    {
      NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
      [style setAlignment:NSCenterTextAlignment];
      attributes = @{
        NSFontAttributeName : METRICS_FONT_SYSTEM_BOLD_13,
        NSForegroundColorAttributeName : [NSColor textColor],
        NSParagraphStyleAttributeName : style
      };
    }
  return attributes;
}

static NSDictionary *AGSummaryAttributes(void)
{
  static NSDictionary *attributes = nil;
  if (attributes == nil)
    {
      NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
      [style setAlignment:NSCenterTextAlignment];
      attributes = @{
        NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_11,
        NSForegroundColorAttributeName : [NSColor disabledControlTextColor],
        NSParagraphStyleAttributeName : style
      };
    }
  return attributes;
}

static CGFloat AGLineHeight(NSDictionary *attributes)
{
  CGFloat height = [@"Ag" sizeWithAttributes:attributes].height;
  /* Rounded up: an underestimated box would clip the last line's descender. */
  return ceil(height);
}

#pragma mark - Truncation

/*
 * Would the text occupy at most maxLines lines in maxWidth?
 *
 * The measuring box is deliberately taller than maxLines: the text system
 * stops laying out lines at the bottom edge of the container, so measuring
 * in an exactly maxLines-tall box would report every string as fitting.
 */
static BOOL AGFitsInLines(NSString *text, NSDictionary *attributes,
                          CGFloat maxWidth, CGFloat lineHeight,
                          NSUInteger maxLines)
{
  if (text == nil || [text length] == 0)
    return YES;
  if (maxWidth <= 1.0)
    return NO;

  CGFloat budget = lineHeight * ((CGFloat)maxLines + 8.0);
  NSSize needed = [text boundingRectWithSize:NSMakeSize(maxWidth, budget)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:attributes].size;
  return ceil(needed.height) <= lineHeight * (CGFloat)maxLines + 1.0;
}

/*
 * The longest prefix that still fits, with a horizontal ellipsis appended.
 * Cut points are snapped to composed character sequences so an accent or a
 * surrogate pair is never split in half, and the search is a binary one
 * because this runs once per card per bind and a linear walk would be the
 * only measurable cost on first layout of fifteen hundred items.
 */
static NSString *AGTruncateToLines(NSString *text, NSDictionary *attributes,
                                   CGFloat maxWidth, CGFloat lineHeight,
                                   NSUInteger maxLines)
{
  static NSString *const ellipsis = @"\u2026";
  if (text == nil || [text length] == 0)
    return text;
  if (AGFitsInLines(text, attributes, maxWidth, lineHeight, maxLines))
    return text;

  NSUInteger length = [text length];
  NSUInteger best = 0;
  NSUInteger low = 1;
  NSUInteger high = length;

  while (low <= high)
    {
      NSUInteger mid = low + (high - low) / 2;
      NSRange sequence = [text rangeOfComposedCharacterSequenceAtIndex:mid - 1];
      NSUInteger cut = NSMaxRange(sequence);
      if (cut > length)
        cut = length;

      NSString *candidate =
          [[text substringToIndex:cut] stringByAppendingString:ellipsis];
      if (AGFitsInLines(candidate, attributes, maxWidth, lineHeight, maxLines))
        {
          if (cut > best)
            best = cut;
          low = mid + 1;
        }
      else
        {
          if (mid == 1)
            break;
          high = mid - 1;
        }
    }

  if (best == 0)
    return ellipsis;
  return [[text substringToIndex:best] stringByAppendingString:ellipsis];
}

#pragma mark -

@implementation AGAppCardView
{
  AGInstallButton *_installButton;
  NSString *_nameText;
  NSString *_summaryText;
  /* Resolved when the app is bound rather than in drawRect: rendering a tile
   * needs its own drawing surface, and creating one halfway through a display
   * pass is the one thing worth avoiding. */
  NSImage *_placeholderIcon;
  NSRect _iconRect;
  NSRect _nameRect;
  NSRect _summaryRect;
  NSTrackingRectTag _trackingTag;
  BOOL _hovered;
}

- (instancetype)initWithFrame:(NSRect)frame installer:(AGInstaller *)installer
{
  /* super's initializer runs setFrameSize:, which lays out while the button
   * and the app are still nil; that pass is harmless, and layoutSubviews is
   * run again below once everything exists. */
  self = [super initWithFrame:frame];
  if (self != nil)
    {
      _installButton =
          [[AGInstallButton alloc] initWithFrame:NSZeroRect
                                          style:AGInstallButtonStyleCard
                                      installer:installer];
      [self addSubview:_installButton];
      [self layoutSubviews];
    }
  return self;
}

- (instancetype)initWithFrame:(NSRect)frame
{
  return [self initWithFrame:frame installer:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  (void)coder;
  return [self initWithFrame:NSZeroRect installer:nil];
}

- (void)dealloc
{
  if (_trackingTag != 0)
    [self removeTrackingRect:_trackingTag];
}

- (BOOL)isFlipped
{
  /* AGGridLayout writes y-down frames; the card continues that convention so
   * the grid's arithmetic does not have to be inverted at the boundary. */
  return YES;
}

+ (NSSize)cardSize
{
  return NSMakeSize(kAGCardWidth, kAGCardHeight);
}

#pragma mark - Geometry

- (void)setFrameSize:(NSSize)size
{
  [super setFrameSize:size];
  [self resetTrackingRect];
  [self layoutSubviews];
}

- (void)setFrame:(NSRect)frame
{
  [super setFrame:frame];
  [self resetTrackingRect];
  [self layoutSubviews];
}

/*
 * Positions the icon, both text blocks and the button, and re-cuts the
 * strings to the new width. Top padding, the icon-to-name gap and the bottom
 * padding are the same 16 points so the card reads as one column rather than
 * as three stacked pieces.
 */
- (void)layoutSubviews
{
  NSRect bounds = [self bounds];
  CGFloat width = NSWidth(bounds);
  CGFloat height = NSHeight(bounds);
  if (width < 8.0 || height < 8.0)
    return;

  _iconRect = NSMakeRect(floor((width - kAGIconSide) / 2.0),
                         METRICS_SPACE_16, kAGIconSide, kAGIconSide);

  NSDictionary *nameAttributes = AGNameAttributes();
  NSDictionary *summaryAttributes = AGSummaryAttributes();
  CGFloat nameLineHeight = AGLineHeight(nameAttributes);
  CGFloat summaryLineHeight = AGLineHeight(summaryAttributes);

  CGFloat textWidth = width - 2.0 * METRICS_SPACE_12;
  if (textWidth < 8.0)
    textWidth = 8.0;

  _nameRect = NSMakeRect(METRICS_SPACE_12,
                         NSMaxY(_iconRect) + METRICS_SPACE_12,
                         textWidth, nameLineHeight);
  _summaryRect = NSMakeRect(METRICS_SPACE_12,
                            NSMaxY(_nameRect) + kAGNameSummaryGap,
                            textWidth, summaryLineHeight * 2.0);

  /* The button stays pinned to the bottom no matter how much text sits above
   * it, so every card's primary action is at the same height and the eye
   * does not have to hunt for it. */
  NSSize buttonSize = [AGInstallButton sizeForStyle:AGInstallButtonStyleCard];
  [_installButton setFrame:NSMakeRect(floor((width - buttonSize.width) / 2.0),
                                      height - METRICS_SPACE_16 - buttonSize.height,
                                      buttonSize.width, buttonSize.height)];

  AGApp *app = _app;
  if (app == nil)
    {
      _nameText = nil;
      _summaryText = nil;
      return;
    }
  _nameText = AGTruncateToLines([app displayName], nameAttributes,
                                textWidth, nameLineHeight, 1);
  _summaryText = AGTruncateToLines([app summary], summaryAttributes,
                                   textWidth, summaryLineHeight, 2);
}

#pragma mark - Binding

- (NSString *)title
{
  return [_app displayName];
}

- (void)setApp:(AGApp *)app
{
  if (_app == app)
    return;
  _app = app;
  /* The previous item's icon must never survive into this card: a pooled
   * card is rebound faster than a cache lookup could be trusted to agree. */
  _icon = nil;
  _placeholderIcon = (app != nil)
      ? [AGPlaceholderIcon placeholderIconForDisplayName:[app displayName]
                                                    size:kAGIconSide]
      : nil;
  [_installButton setApp:app];
  [self layoutSubviews];
  [self setNeedsDisplay:YES];
}

- (void)setIcon:(NSImage *)icon
{
  if (_icon == icon)
    return;
  _icon = icon;
  [self setNeedsDisplay:YES];
}

- (void)setFocused:(BOOL)focused
{
  if (_focused == focused)
    return;
  _focused = focused;
  [self setNeedsDisplay:YES];
}

#pragma mark - Hover

- (void)resetTrackingRect
{
  if (_trackingTag != 0)
    {
      [self removeTrackingRect:_trackingTag];
      _trackingTag = 0;
    }
  if ([self window] == nil || NSIsEmptyRect([self bounds]))
    return;
  /* The tag stays valid across moves and resizes because the rect is stored
   * in this view's coordinates and converted per event; only a window change
   * or a bounds change needs a new tag, which is why there is no
   * updateTrackingAreas here. */
  _trackingTag = [self addTrackingRect:[self bounds]
                                 owner:self
                              userData:NULL
                          assumeInside:NO];
}

- (void)refreshHoverFromMouse
{
  BOOL hovered = NO;
  NSWindow *window = [self window];
  if (window != nil)
    {
      NSPoint point = [self convertPoint:[window mouseLocationOutsideOfEventStream]
                               fromView:nil];
      hovered = NSMouseInRect(point, [self bounds], [self isFlipped]);
    }
  if (hovered == _hovered)
    return;
  _hovered = hovered;
  [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  /* A recycled card leaves the window while the pointer may still be over
   * it, and no exit event is delivered to a view that is no longer in the
   * tree; recomputing here is what stops the previous card's hover border
   * from travelling with it. */
  [self resetTrackingRect];
  [self refreshHoverFromMouse];
}

- (void)mouseEntered:(NSEvent *)event
{
  (void)event;
  if (_hovered)
    return;
  _hovered = YES;
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event
{
  (void)event;
  if (!_hovered)
    return;
  _hovered = NO;
  [self setNeedsDisplay:YES];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect
{
  (void)dirtyRect;

  NSRect bounds = [self bounds];
  if (NSIsEmptyRect(bounds))
    return;

  NSRect cardRect = NSInsetRect(bounds, 0.5, 0.5);
  NSBezierPath *card =
      [NSBezierPath bezierPathWithRoundedRect:cardRect
                                    xRadius:kAGCardCornerRadius
                                    yRadius:kAGCardCornerRadius];

  [[NSColor controlBackgroundColor] setFill];
  [card fill];

  if (_app != nil)
    {
      [self drawIcon];
      if (_nameText != nil)
        [_nameText drawInRect:_nameRect withAttributes:AGNameAttributes()];
      if (_summaryText != nil)
        [_summaryText drawInRect:_summaryRect withAttributes:AGSummaryAttributes()];
    }

  /* Drawn last so a 2-point ring sits over the card edge instead of half of
   * it falling outside the fill. */
  NSColor *borderColor = AGCardBorderColor();
  CGFloat borderWidth = 1.0;
  if (_focused)
    {
      borderColor = AGAccentColor();
      borderWidth = 2.0;
    }
  else if (_hovered)
    {
      borderColor = [AGAccentColor() colorWithAlphaComponent:0.5];
      borderWidth = 2.0;
    }
  [borderColor setStroke];
  [card setLineWidth:borderWidth];
  [card stroke];
}

- (void)drawIcon
{
  NSImage *image = (_icon != nil) ? _icon : _placeholderIcon;
  if (image == nil)
    return;

  NSGraphicsContext *context = [NSGraphicsContext currentContext];
  NSImageInterpolation saved = [context imageInterpolation];
  [context setImageInterpolation:NSImageInterpolationHigh];
  /* respectFlipped keeps the picture upright in this flipped view. */
  [image drawInRect:_iconRect
           fromRect:NSZeroRect
          operation:NSCompositeSourceOver
           fraction:1.0
      respectFlipped:YES
              hints:nil];
  [context setImageInterpolation:saved];
}

#pragma mark - Interaction

- (void)mouseDown:(NSEvent *)event
{
  (void)event;
  if (_app == nil)
    return;
  /* Fired on the press rather than on a press-to-release match: a card has no
   * drag gesture of its own to distinguish, and tracking one here would eat
   * the mouse-drag events a surrounding scroller may want. The install button
   * below does track, because starting a download by accident costs more
   * than opening a detail page does. */
  [self.delegate appCardViewWasClicked:self];
}

@end
