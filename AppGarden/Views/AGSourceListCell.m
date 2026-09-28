/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGSourceListCell.h"
#import "AppearanceMetrics.h"

static const CGFloat kAGSourceRowHeight = 24.0;
static const CGFloat kAGSourceSpacerHeight = 12.0;
/* Left inset of a label: items sit further in than headers, so the two
 * columns of text do not read as one list of items. */
static const CGFloat kAGSourceItemInset = 12.0;
static const CGFloat kAGSourceHeaderInset = 8.0;
static const CGFloat kAGSourceCountInset = 12.0;
static const CGFloat kAGSourceCountGap = 8.0;

/* Small caps only where the font set really has the trait: asking a font
 * manager for a trait it cannot supply returns the font unchanged, and a
 * section label that silently stops being small caps is still a section
 * label, so the bold fallback is explicit rather than accidental. */
static NSFont *AGSourceHeaderFont(void)
{
  static NSFont *font = nil;
  if (font == nil)
    {
      NSFont *bold = METRICS_FONT_SYSTEM_BOLD_11;
      NSFontManager *manager = [NSFontManager sharedFontManager];
      NSFont *smallCaps = [manager convertFont:bold
                                    toHaveTrait:(NSBoldFontMask |
                                                  NSSmallCapsFontMask)];
      if (smallCaps != nil &&
          (([manager traitsOfFont:smallCaps] & NSSmallCapsFontMask) != 0))
        font = smallCaps;
      else
        font = bold;
    }
  return font;
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

/* The y a single measured line starts at to sit centered in frame. Measuring
 * first is what makes this right in a flipped and an unflipped table alike. */
static CGFloat AGSourceCenteredTop(NSSize textSize, NSRect frame)
{
  return NSMidY(frame) - textSize.height / 2.0;
}

@implementation AGSourceListCell

+ (CGFloat)rowHeight
{
  return kAGSourceRowHeight;
}

+ (CGFloat)spacerRowHeight
{
  return kAGSourceSpacerHeight;
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
  NSString *title = [self stringValue];
  if ([title length] == 0)
    return;

  NSDictionary *attributes = AGSourceHeaderAttributes();
  NSSize size = [title sizeWithAttributes:attributes];
  CGFloat width = NSWidth(frame) - kAGSourceHeaderInset;
  if (width <= 0.0)
    return;
  NSRect line = NSMakeRect(NSMinX(frame) + kAGSourceHeaderInset,
                           AGSourceCenteredTop(size, frame),
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

  CGFloat labelX = NSMinX(frame) + kAGSourceItemInset;
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
          NSRect line = NSMakeRect(labelX, AGSourceCenteredTop(size, frame),
                                   maxWidth, size.height);
          [title drawInRect:line withAttributes:attributes];
        }
    }

  if ([count length] > 0 && countWidth > kAGSourceCountGap)
    {
      NSDictionary *attributes = AGSourceCountAttributes(countColor);
      NSSize size = [count sizeWithAttributes:attributes];
      NSRect line = NSMakeRect(rightEdge - size.width,
                               AGSourceCenteredTop(size, frame),
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
