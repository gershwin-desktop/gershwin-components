/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BookshelfView.h"
#include <math.h>

static const CGFloat kShelfHeight = 232.0;
static const CGFloat kBoardThickness = 18.0;
static const CGFloat kSpineWidth = 54.0;
static const CGFloat kSpineGap = 12.0;
static const CGFloat kInset = 24.0;
static const CGFloat kTopInset = 24.0;

@interface BookshelfView ()
{
  NSMutableArray<NSValue *> *_bookRects;
  NSImage *_wood;
  NSTimeInterval _lastClickTime;
  NSInteger _lastClickIndex;
}
@end

@implementation BookshelfView

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if (self)
    {
      _bookRects = [NSMutableArray array];
      _selectedIndex = -1;
      _wood = [self bundleImage:@"wood"];
      [self registerForDraggedTypes:@[ NSFilenamesPboardType ]];
    }
  return self;
}

- (NSImage *)bundleImage:(NSString *)name
{
  NSImage *img = [NSImage imageNamed:name];
  if (img == nil)
    {
      NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];
      if (p) img = [[NSImage alloc] initWithContentsOfFile:p];
    }
  return img;
}

- (void)setBooks:(NSArray<LibraryBook *> *)books
{
  _books = [books copy];
  [self reloadData];
}

- (void)reloadData
{
  [self layoutBooks];
  [self setNeedsDisplay:YES];
}

+ (NSInteger)booksPerRowForWidth:(CGFloat)w
{
  CGFloat usable = w - 2.0 * kInset + kSpineGap;
  return MAX(1, (NSInteger)(usable / (kSpineWidth + kSpineGap)));
}

+ (CGFloat)contentHeightForCount:(NSInteger)count width:(CGFloat)w
{
  NSInteger perRow = [self booksPerRowForWidth:w];
  NSInteger rows = MAX(1, (count + perRow - 1) / perRow);
  return kTopInset + (CGFloat)rows * kShelfHeight;
}

// WHY a pure function of count and width: the rects must not depend on the
// current frame height or on earlier layouts, or live resizing would move
// the books by the amount the visible height changes.
+ (NSArray<NSValue *> *)spineRectsForCount:(NSInteger)count width:(CGFloat)w
{
  NSInteger perRow = [self booksPerRowForWidth:w];
  NSMutableArray *rects = [NSMutableArray arrayWithCapacity:count];
  for (NSInteger i = 0; i < count; i++)
    {
      NSInteger row = i / perRow;
      NSInteger col = i % perRow;
      CGFloat x = kInset + (CGFloat)col * (kSpineWidth + kSpineGap);
      CGFloat bookH = kShelfHeight - kBoardThickness - 14.0 - (CGFloat)(i % 3) * 10.0;
      // Books stand on the board at the bottom of their shelf row; rows run
      // top to bottom because the view is flipped.
      CGFloat boardY = kTopInset + (CGFloat)row * kShelfHeight
                       + kShelfHeight - kBoardThickness;
      [rects addObject:[NSValue valueWithRect:
          NSMakeRect(x, boardY + 2.0 - bookH, kSpineWidth, bookH)]];
    }
  return rects;
}

// WHY flipped: the scroll view rounds a bottom-up document's origin to whole
// window units while the visible height is fractional (GSScaleFactor 1.2),
// so content placed relative to the top jittered during live resize. A
// flipped view keeps the origin at 0 and the first shelf at the top.
- (BOOL)isFlipped
{
  return YES;
}

- (void)setFrameSize:(NSSize)size
{
  CGFloat oldW = [self frame].size.width;
  [super setFrameSize:size];
  // Height-only changes (the clip view resizing us) leave the layout alone.
  if (size.width != oldW)
    [self layoutBooks];
}

- (void)layoutBooks
{
  NSRect b = [self bounds];
  NSInteger count = [_books count];
  [_bookRects setArray:[[self class] spineRectsForCount:count width:b.size.width]];

  // Fill the visible area so the wood has no gap below the last shelf; the
  // document never shrinks below its shelves.
  CGFloat totalH = [[self class] contentHeightForCount:count width:b.size.width];
  CGFloat visibleH = [self enclosingScrollView]
      ? [[self enclosingScrollView] contentSize].height : 0.0;
  CGFloat h = MAX(totalH, visibleH);
  if (h != b.size.height)
    [super setFrameSize:NSMakeSize(b.size.width, h)];
}

- (NSRect)rectForBookAtIndex:(NSInteger)index
{
  if (index < 0 || index >= (NSInteger)[_bookRects count])
    return NSZeroRect;
  return [_bookRects[index] rectValue];
}

- (void)drawRect:(NSRect)dirty
{
  NSRect b = [self bounds];
  if (_wood)
    {
      // WHY: patterns are anchored to the window's lower-left corner, so a
      // window resized at its bottom edge slid the wood under the books.
      // Anchoring to the view's top-left corner keeps it still.
      [[NSGraphicsContext currentContext]
          setPatternPhase:[self convertPoint:NSZeroPoint toView:nil]];
      [[NSColor colorWithPatternImage:_wood] set];
      NSRectFill(b);
    }
  else
    {
      [[NSColor colorWithCalibratedRed:0.35 green:0.22 blue:0.12 alpha:1.0] set];
      NSRectFill(b);
    }

  NSInteger rows = (NSInteger)([_bookRects count] == 0 ? 1 :
      (ceil((double)[_bookRects count] / (double)[[self class] booksPerRowForWidth:b.size.width])));
  for (NSInteger r = 0; r < rows; r++)
    {
      CGFloat boardY = kTopInset + (CGFloat)r * kShelfHeight
                       + kShelfHeight - kBoardThickness;
      [self drawShelfBoard:NSMakeRect(0, boardY, b.size.width, kBoardThickness)];
    }

  for (NSInteger i = 0; i < (NSInteger)[_bookRects count]; i++)
    {
      [self drawSpine:[_bookRects[i] rectValue] book:_books[i] selected:(i == _selectedIndex)];
    }
}

- (void)drawShelfBoard:(NSRect)r
{
  NSGradient *g = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithCalibratedRed:0.30 green:0.18 blue:0.09 alpha:1.0]
                endingColor:[NSColor colorWithCalibratedRed:0.18 green:0.10 blue:0.05 alpha:1.0]];
  [g drawInRect:r angle:90.0];
  [[NSColor colorWithCalibratedWhite:0.0 alpha:0.35] set];
  NSRectFill(NSMakeRect(r.origin.x, r.origin.y - 6.0, r.size.width, 6.0));
  [[NSColor colorWithCalibratedRed:0.45 green:0.30 blue:0.16 alpha:0.9] set];
  NSRectFill(NSMakeRect(r.origin.x, r.origin.y + r.size.height - 2.0, r.size.width, 2.0));
}

- (NSColor *)spineColorForTitle:(NSString *)title
{
  NSUInteger h = [title hash];
  CGFloat hue = 0.04 + (CGFloat)(h % 40) / 400.0;
  CGFloat sat = 0.45 + (CGFloat)((h >> 3) % 30) / 200.0;
  return [NSColor colorWithCalibratedHue:hue saturation:sat brightness:0.42 alpha:1.0];
}

- (void)drawSpine:(NSRect)r book:(LibraryBook *)book selected:(BOOL)selected
{
  NSColor *base = [self spineColorForTitle:[book displayTitle]];
  NSGradient *g = [[NSGradient alloc]
      initWithStartingColor:[base colorWithAlphaComponent:1.0]
                endingColor:[base shadowWithLevel:0.45]];
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4.0 yRadius:4.0];
  // WHY: setClip intersects with the current clip; without a state restore
  // every spine after the first was clipped away by the previous one's path.
  [NSGraphicsContext saveGraphicsState];
  [g drawInRect:r angle:0.0];
  [path setClip];

  [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] set];
  NSRectFill(NSMakeRect(r.origin.x + 3.0, r.origin.y, 3.0, r.size.height));
  [[NSColor colorWithCalibratedWhite:0.0 alpha:0.25] set];
  NSRectFill(NSMakeRect(r.origin.x + r.size.width - 4.0, r.origin.y, 3.0, r.size.height));

  [self drawVerticalText:[book displayTitle] inRect:r];
  [path setClip];

  if (selected)
    {
      [[NSColor colorWithCalibratedRed:0.98 green:0.85 blue:0.4 alpha:0.9] set];
      [NSBezierPath setDefaultLineWidth:3.0];
      [NSBezierPath strokeRect:NSInsetRect(r, 1.5, 1.5)];
    }
  else
    {
      [[NSColor colorWithCalibratedWhite:0.0 alpha:0.5] set];
      [NSBezierPath setDefaultLineWidth:1.0];
      [NSBezierPath strokeRect:NSInsetRect(r, 0.5, 0.5)];
    }
  [NSGraphicsContext restoreGraphicsState];
}

- (void)drawVerticalText:(NSString *)text inRect:(NSRect)r
{
  if ([text length] == 0) return;
  NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:11.0],
                           NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0] };
  NSSize ts = [text sizeWithAttributes:attrs];
  CGFloat maxH = r.size.height - 16.0;
  if (ts.width > maxH)
    {
      NSInteger max = (NSInteger)(maxH / (ts.width / (CGFloat)[text length]));
      if (max < (NSInteger)[text length])
        text = [[text substringToIndex:MAX(1, max - 1)] stringByAppendingString:@"…"];
    }
  [NSGraphicsContext saveGraphicsState];
  NSAffineTransform *t = [NSAffineTransform transform];
  // Flipped view: +90 turns clockwise, so the title still reads from the
  // top of the spine downwards.
  [t translateXBy:r.origin.x + r.size.width / 2.0 yBy:r.origin.y + 8.0];
  [t rotateByDegrees:90.0];
  [t concat];
  [text drawAtPoint:NSMakePoint(0, -5.0) withAttributes:attrs];
  [NSGraphicsContext restoreGraphicsState];
}

- (NSInteger)bookIndexAtPoint:(NSPoint)p
{
  for (NSInteger i = 0; i < (NSInteger)[_bookRects count]; i++)
    {
      if (NSMouseInRect(p, [_bookRects[i] rectValue], NO))
        return i;
    }
  return -1;
}

- (void)mouseDown:(NSEvent *)event
{
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSInteger idx = [self bookIndexAtPoint:p];
  if (idx != _selectedIndex)
    {
      _selectedIndex = idx;
      [self setNeedsDisplay:YES];
    }

  // WHY manual double-click: GNUstep's NSEvent clickCount is unreliable, so we
  // detect a double-click ourselves by comparing time and index of the last
  // mouseDown.
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  BOOL isDouble = (idx >= 0 && idx == _lastClickIndex &&
                   (now - _lastClickTime) < 0.4);
  _lastClickTime = now;
  _lastClickIndex = idx;

  if (isDouble && idx >= 0)
    {
      _lastClickIndex = -1;
      if (_delegate && [_delegate respondsToSelector:@selector(bookshelfDidRequestOpen:)])
        [_delegate bookshelfDidRequestOpen:_books[idx]];
    }
}

- (void)keyDown:(NSEvent *)event
{
  NSString *s = [event characters];
  if ([s length] && ([s characterAtIndex:0] == NSCarriageReturnCharacter ||
                     [s characterAtIndex:0] == NSEnterCharacter))
    {
      if (_selectedIndex >= 0 && _delegate)
        [_delegate bookshelfDidRequestOpen:_books[_selectedIndex]];
    }
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
  NSPasteboard *pb = [sender draggingPasteboard];
  if ([[pb types] containsObject:NSFilenamesPboardType])
    {
      NSArray *files = [pb propertyListForType:NSFilenamesPboardType];
      for (NSString *f in files)
        if ([[f pathExtension] caseInsensitiveCompare:@"epub"] == NSOrderedSame)
          return NSDragOperationCopy;
    }
  return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
  NSPasteboard *pb = [sender draggingPasteboard];
  NSArray *files = [pb propertyListForType:NSFilenamesPboardType];
  NSMutableArray *epubs = [NSMutableArray array];
  for (NSString *f in files)
    if ([[f pathExtension] caseInsensitiveCompare:@"epub"] == NSOrderedSame)
      [epubs addObject:f];
  if ([epubs count] && _delegate &&
      [_delegate respondsToSelector:@selector(bookshelfDidRequestAddFiles:)])
    [_delegate bookshelfDidRequestAddFiles:epubs];
  return YES;
}

@end
