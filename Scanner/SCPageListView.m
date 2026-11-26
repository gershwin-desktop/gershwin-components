/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPageListView.h"
#import "SCImage.h"
#import "SCImageWriter.h"
#import "SCMetrics.h"

static const CGFloat SCThumbMargin = 8;
static const CGFloat SCLabelHeight = 15;

@implementation SCPageListView
{
  /* Thumbnails are made once per page and dropped with it, see -setPages: */
  NSMapTable *_thumbnails;
  NSMutableArray *_frames;
}

- (instancetype) initWithFrame: (NSRect)frame
{
  self = [super initWithFrame: frame];
  if (self)
    {
      _thumbnails = [NSMapTable strongToStrongObjectsMapTable];
      _frames = [NSMutableArray array];
      _pages = @[];
      _showsBed = YES;
    }
  return self;
}

- (BOOL) isFlipped
{
  return YES;
}

- (BOOL) acceptsFirstResponder
{
  return YES;
}

- (void) setPages: (NSArray *)pages
{
  _pages = [pages copy];
  for (id page in [[_thumbnails keyEnumerator] allObjects])
    {
      if ([_pages indexOfObjectIdenticalTo: page] == NSNotFound)
        {
          [_thumbnails removeObjectForKey: page];
        }
    }
  if (_selectedIndex > (NSInteger)[_pages count])
    {
      _selectedIndex = [_pages count];
    }
  [self reload];
}

- (void) setShowsBed: (BOOL)shows
{
  if (shows != _showsBed)
    {
      _showsBed = shows;
      [self reload];
    }
}

- (void) setBedImage: (NSImage *)image
{
  _bedImage = image;
  [self reload];
}

- (void) setSelectedIndex: (NSInteger)index
{
  _selectedIndex = index;
  [self setNeedsDisplay: YES];
  if (index >= 0 && index < (NSInteger)[_frames count])
    {
      [self scrollRectToVisible: [[_frames objectAtIndex: index] rectValue]];
    }
}

- (NSImage *) thumbnailForPage: (SCImage *)page width: (CGFloat)width
{
  NSImage *thumb = [_thumbnails objectForKey: page];

  if (thumb == nil)
    {
      /* Small enough to keep for every page, sharp enough for the column */
      SCImage *eight = [page eightBitImage];
      NSBitmapImageRep *rep = [SCImageWriter bitmapForImage: eight];
      CGFloat scale = MIN(1.0, 2 * width / MAX(1, [page width]));

      thumb = [[NSImage alloc] initWithSize:
                 NSMakeSize([page width] * scale, [page height] * scale)];
      [rep setSize: [thumb size]];
      [thumb addRepresentation: rep];
      [_thumbnails setObject: thumb forKey: page];
    }
  return thumb;
}

- (NSSize) sizeOfImage: (NSImage *)image fittingWidth: (CGFloat)width
{
  NSSize s = image ? [image size] : NSMakeSize(210, 297);
  CGFloat h = width * s.height / MAX(1, s.width);

  /* Very long pages (receipts) would push everything else away */
  return NSMakeSize(width, MIN(h, width * 2));
}

- (void) reload
{
  /* The clip view's width: a scroller that appears makes it narrower */
  CGFloat full = [self superview] ? NSWidth([[self superview] bounds])
                                  : NSWidth([self frame]);
  CGFloat width = full - 2 * SCThumbMargin;
  CGFloat y = SCThumbMargin;
  NSUInteger i;

  [_frames removeAllObjects];
  for (i = 0; i <= [_pages count]; i++)
    {
      NSImage *image;
      NSSize s;
      CGFloat h;

      if (i == 0 && !_showsBed)
        {
          /* Keeps index 0 for the bed, so page indexes never shift */
          [_frames addObject: [NSValue valueWithRect: NSZeroRect]];
          continue;
        }
      image = (i == 0) ? _bedImage
        : [self thumbnailForPage: [_pages objectAtIndex: i - 1] width: width];
      s = [self sizeOfImage: image fittingWidth: width];
      h = s.height + 4 + 2 * SCLabelHeight;

      [_frames addObject: [NSValue valueWithRect:
        NSMakeRect(SCThumbMargin, y, width, h)]];
      y += h + SCThumbMargin * 2;
    }
  [self setFrameSize: NSMakeSize(full, MAX(y, NSHeight([[self superview] bounds])))];
  [self setNeedsDisplay: YES];
}

- (void) drawLabel: (NSString *)text inRect: (NSRect)r font: (NSFont *)font
{
  NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];

  [p setAlignment: NSCenterTextAlignment];
  [p setLineBreakMode: NSLineBreakByTruncatingTail];
  [text drawInRect: r withAttributes: @{NSFontAttributeName: font,
                                        NSParagraphStyleAttributeName: p,
                                        NSForegroundColorAttributeName:
                                          [NSColor controlTextColor]}];
}

- (void) drawRect: (NSRect)dirty
{
  NSUInteger i;

  [[NSColor controlBackgroundColor] set];
  NSRectFill(dirty);
  for (i = 0; i < [_frames count]; i++)
    {
      NSRect cell = [[_frames objectAtIndex: i] rectValue];
      NSImage *image = (i == 0) ? _bedImage
        : [_thumbnails objectForKey: [_pages objectAtIndex: i - 1]];
      NSSize s = [self sizeOfImage: image fittingWidth: NSWidth(cell)];
      NSRect box = NSMakeRect(NSMinX(cell), NSMinY(cell), s.width, s.height);
      NSString *note = (i == 0) ? nil
        : [_delegate pageList: self noteForPage: [_pages objectAtIndex: i - 1]];

      if (NSIsEmptyRect(cell) || !NSIntersectsRect(NSInsetRect(cell, -4, -4), dirty))
        {
          continue;
        }
      if ((NSInteger)i == _selectedIndex)
        {
          [[NSColor selectedControlColor] set];
          NSRectFill(NSInsetRect(cell, -4, -4));
        }
      if (image != nil)
        {
          [image drawInRect: box fromRect: NSZeroRect
                  operation: NSCompositeSourceOver fraction: 1.0];
        }
      else
        {
          [[NSColor whiteColor] set];
          NSRectFill(box);
        }
      [[NSColor grayColor] set];
      NSFrameRect(box);
      [self drawLabel: (i == 0) ? @"Scanner Bed"
                       : [NSString stringWithFormat: @"Page %lu", (unsigned long)i]
               inRect: NSMakeRect(NSMinX(cell), NSMaxY(box) + 4, NSWidth(cell),
                                  SCLabelHeight)
                 font: [NSFont systemFontOfSize: 11]];
      if (note != nil)
        {
          [self drawLabel: note
                   inRect: NSMakeRect(NSMinX(cell), NSMaxY(box) + 4 + SCLabelHeight,
                                      NSWidth(cell), SCLabelHeight)
                     font: [NSFont systemFontOfSize: 10]];
        }
    }
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSUInteger i;

  [[self window] makeFirstResponder: self];
  for (i = 0; i < [_frames count]; i++)
    {
      NSRect cell = [[_frames objectAtIndex: i] rectValue];

      if (!NSIsEmptyRect(cell) && NSPointInRect(p, NSInsetRect(cell, -4, -4)))
        {
          [self setSelectedIndex: i];
          [_delegate pageList: self didSelectIndex: i];
          return;
        }
    }
}

- (void) keyDown: (NSEvent *)event
{
  NSString *chars = [event charactersIgnoringModifiers];
  unichar c = [chars length] ? [chars characterAtIndex: 0] : 0;
  NSInteger count = [_pages count];

  if ((c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey)
      && _selectedIndex > 0)
    {
      [_delegate pageListDeleteSelected: self];
      return;
    }
  if (c == NSUpArrowFunctionKey && _selectedIndex > (_showsBed ? 0 : 1))
    {
      [self setSelectedIndex: _selectedIndex - 1];
      [_delegate pageList: self didSelectIndex: _selectedIndex];
      return;
    }
  if (c == NSDownArrowFunctionKey && _selectedIndex < count)
    {
      [self setSelectedIndex: _selectedIndex + 1];
      [_delegate pageList: self didSelectIndex: _selectedIndex];
      return;
    }
  [super keyDown: event];
}

- (void) delete: (id)sender
{
  if (_selectedIndex > 0)
    {
      [_delegate pageListDeleteSelected: self];
    }
}

@end
