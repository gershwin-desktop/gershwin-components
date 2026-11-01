/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGSourceListCell.h"
#import "AppearanceMetrics.h"

static const CGFloat kAGSourceRowHeight = 24.0;
static const CGFloat kAGSourceSpacerHeight = 12.0;
/* Headers and glyphs share one left inset; an item's label starts after the
 * glyph column so the two columns of text do not read as one list. */
static const CGFloat kAGSourceLeftInset = 12.0;
static const CGFloat kAGSourceIconSide = 16.0;
static const CGFloat kAGSourceIconGap = 8.0;
static const CGFloat kAGSourceCountInset = 12.0;
static const CGFloat kAGSourceCountGap = 8.0;

/* Section titles are bold capitals: no font here carries a small-caps
 * trait, and capitals set them apart from the items at a glance. */
static NSFont *AGSourceHeaderFont(void)
{
  return METRICS_FONT_SYSTEM_BOLD_11;
}

/* Built once: a paragraph style is immutable here, and a row list redrawn on
 * every scroll should not allocate one per row per frame. */
static NSParagraphStyle *AGSourceTruncatingStyle(void)
{
  static NSParagraphStyle *style = nil;
  if (style == nil)
    {
      NSMutableParagraphStyle *mutable = [[NSMutableParagraphStyle alloc] init];
      [mutable setAlignment:NSLeftTextAlignment];
      [mutable setLineBreakMode:NSLineBreakByTruncatingTail];
      style = mutable;
    }
  return style;
}

static NSDictionary *AGSourceItemAttributes(NSColor *color)
{
  return @{
    NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_13,
    NSForegroundColorAttributeName : color,
    NSParagraphStyleAttributeName : AGSourceTruncatingStyle()
  };
}

static NSDictionary *AGSourceHeaderAttributes(void)
{
  static NSDictionary *attributes = nil;
  if (attributes == nil)
    {
      attributes = @{
        NSFontAttributeName : AGSourceHeaderFont(),
        NSForegroundColorAttributeName : [NSColor disabledControlTextColor]
      };
    }
  return attributes;
}

static NSDictionary *AGSourceCountAttributes(NSColor *color)
{
  return @{
    NSFontAttributeName : METRICS_FONT_SYSTEM_REGULAR_11,
    NSForegroundColorAttributeName : color
  };
}

/* The y a single line starts at so that its capitals sit centered in frame.
 * Centering the line box instead put the glyphs about four points high: the
 * box carries the descender and this font's generous ascender, neither of
 * which the eye counts. The cap height comes from the cairo backend patch
 * cairo-cap-height-x-height (unpatched backends report 0 and would centre
 * the baseline instead). */
static CGFloat AGSourceCenteredTop(NSDictionary *attributes, NSRect frame)
{
  NSFont *font = [attributes objectForKey:NSFontAttributeName];
  CGFloat baseline = NSMidY(frame) + [font capHeight] / 2.0;
  return baseline - [font ascender];
}

static NSRect AGSourceIconRect(NSRect frame)
{
  return NSMakeRect(NSMinX(frame) + kAGSourceLeftInset,
                    floor(NSMidY(frame) - kAGSourceIconSide / 2.0),
                    kAGSourceIconSide, kAGSourceIconSide);
}

@implementation AGSourceListCell

@dynamic countText;

- (NSString *)countText
{
  return [self representedObject];
}

- (void)setCountText:(NSString *)countText
{
  [self setRepresentedObject:[countText copy]];
}

+ (CGFloat)rowHeight
{
  return kAGSourceRowHeight;
}

+ (CGFloat)spacerRowHeight
{
  return kAGSourceSpacerHeight;
}

+ (CGFloat)iconSide
{
  return kAGSourceIconSide;
}

#pragma mark - Drawing

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
  /* super would paint the text field's own string in its own font, and with
   * a bezeled cell a box as well; the sidebar decides both, so this cell
   * draws the row itself and never calls it. */
  switch (_rowKind)
    {
      case AGSourceListRowKindSpacer:
        return;
      case AGSourceListRowKindHeader:
        [self drawHeaderInFrame:cellFrame];
        return;
      case AGSourceListRowKindItem:
        [self drawItemInFrame:cellFrame inView:controlView];
        return;
    }
}

- (void)drawHeaderInFrame:(NSRect)frame
{
  NSString *title = [[self stringValue] uppercaseString];
  if ([title length] == 0)
    return;

  NSDictionary *attributes = AGSourceHeaderAttributes();
  NSSize size = [title sizeWithAttributes:attributes];
  CGFloat width = NSWidth(frame) - kAGSourceLeftInset;
  if (width <= 0.0)
    return;
  NSRect line = NSMakeRect(NSMinX(frame) + kAGSourceLeftInset,
                           AGSourceCenteredTop(attributes, frame),
                           width, size.height);
  [title drawInRect:line withAttributes:attributes];
}

- (void)drawItemInFrame:(NSRect)frame inView:(NSView *)controlView
{
  NSString *title = [self stringValue];
  NSString *count = [self countText];
  BOOL selected = [self rowIsSelectedInView:controlView frame:frame];

  /* The theme paints the selection and, before drawing a selected row,
   * swaps this cell's own text colour for the ink it wants on that
   * highlight, so the cell's colour is the first choice. A table whose
   * theme names no such colour still gets readable text: without this the
   * label would stay dark on a dark highlight. */
  NSColor *color = [self textColor];
  if (selected && [color isEqual:[NSColor textColor]])
    color = [NSColor selectedTextColor];
  /* The count keeps its quiet grey, but on a selected row it takes the
   * label's ink, because grey on a highlight is the one combination that
   * goes illegible. */
  NSColor *countColor = selected ? color : [NSColor disabledControlTextColor];

  NSImage *image = [self image];
  if (image != nil)
    {
      /* respectFlipped: the table is flipped and the glyph would otherwise
       * draw upside down. */
      [image drawInRect:AGSourceIconRect(frame)
               fromRect:NSZeroRect
              operation:NSCompositeSourceOver
               fraction:1.0
         respectFlipped:YES
                  hints:nil];
    }

  CGFloat labelX = NSMinX(frame) + kAGSourceLeftInset + kAGSourceIconSide + kAGSourceIconGap;
  CGFloat rightEdge = NSMaxX(frame) - kAGSourceCountInset;
  CGFloat countWidth = 0.0;

  if ([count length] > 0)
    {
      NSDictionary *countAttributes = AGSourceCountAttributes(countColor);
      countWidth = [count sizeWithAttributes:countAttributes].width;
      /* A count shorter than its own gap still reserves the gap, so the
       * label cannot run into it. */
      if (countWidth > 0.0)
        countWidth += kAGSourceCountGap;
    }

  if ([title length] > 0)
    {
      NSDictionary *attributes = AGSourceItemAttributes(color);
      CGFloat maxWidth = rightEdge - countWidth - labelX;
      if (maxWidth > 0.0)
        {
          NSSize size = [title sizeWithAttributes:attributes];
          NSRect line = NSMakeRect(labelX, AGSourceCenteredTop(attributes, frame),
                                   maxWidth, size.height);
          [title drawInRect:line withAttributes:attributes];
        }
    }

  if ([count length] > 0 && countWidth > kAGSourceCountGap)
    {
      NSDictionary *attributes = AGSourceCountAttributes(countColor);
      NSSize size = [count sizeWithAttributes:attributes];
      NSRect line = NSMakeRect(rightEdge - size.width,
                               AGSourceCenteredTop(attributes, frame),
                               size.width, size.height);
      [count drawInRect:line withAttributes:attributes];
    }
}

/* YES when the row this cell is drawing is the table's selected row. The
 * cell is not told its row, so it asks the table where its own frame fell. */
- (BOOL)rowIsSelectedInView:(NSView *)controlView frame:(NSRect)frame
{
  if ([controlView isKindOfClass:[NSTableView class]])
    {
      NSTableView *table = (NSTableView *)controlView;
      NSInteger row = [table rowAtPoint:NSMakePoint(NSMidX(frame), NSMidY(frame))];
      if (row >= 0 && [table isRowSelected:row])
        return YES;
    }
  return NO;
}

@end
