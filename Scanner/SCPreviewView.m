/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPreviewView.h"
#include <math.h>

/* Handles are hit within this distance in points, at every zoom */
static const CGFloat SCHandleSize = 7;
/* Smaller drags are clicks, not new selections */
static const CGFloat SCMinimumDrag = 4;

typedef NS_ENUM(NSInteger, SCDragMode)
{
  SCDragNone,
  SCDragCreate,
  SCDragMove,
  SCDragResize
};

/* Edge bits for resizing */
enum
{
  SCEdgeLeft = 1,
  SCEdgeRight = 2,
  SCEdgeTop = 4,
  SCEdgeBottom = 8
};

@implementation SCPreviewView
{
  NSMutableArray *_selections;
  NSInteger _active;
  SCDragMode _drag;
  unsigned _edges;
  NSPoint _dragStart;
  NSRect _dragOriginal;
  /* Where the bed is drawn; centered when the view is larger than the image */
  NSRect _bedRect;
}

- (instancetype) initWithFrame: (NSRect)frame
{
  self = [super initWithFrame: frame];
  if (self)
    {
      _selections = [NSMutableArray array];
      _active = -1;
      _bedAspect = NSMakeSize(210, 297);
      _bedRect = [self bounds];
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

- (BOOL) acceptsFirstMouse: (NSEvent *)event
{
  return YES;
}

#pragma mark Geometry

- (NSSize) naturalSize
{
  if (_image != nil)
    {
      return [_image size];
    }
  return _bedAspect;
}

- (NSRect) bedRect
{
  return _bedRect;
}

- (NSRect) viewRectForFraction: (NSRect)f
{
  NSRect bed = [self bedRect];

  return NSMakeRect(NSMinX(bed) + NSMinX(f) * NSWidth(bed),
                    NSMinY(bed) + NSMinY(f) * NSHeight(bed),
                    NSWidth(f) * NSWidth(bed), NSHeight(f) * NSHeight(bed));
}

- (NSPoint) fractionForPoint: (NSPoint)p
{
  NSRect bed = [self bedRect];

  return NSMakePoint(MIN(1, MAX(0, (p.x - NSMinX(bed)) / NSWidth(bed))),
                     MIN(1, MAX(0, (p.y - NSMinY(bed)) / NSHeight(bed))));
}

- (void) updateSize
{
  NSScrollView *scroll = [self enclosingScrollView];
  NSSize natural = [self naturalSize];
  NSSize size;

  if (scroll == nil || natural.width <= 0 || natural.height <= 0)
    {
      return;
    }
  if (_zoom <= 0)
    {
      NSSize visible = [scroll contentSize];
      CGFloat s = MIN(visible.width / natural.width,
                      visible.height / natural.height);

      size = NSMakeSize(floor(natural.width * s), floor(natural.height * s));
    }
  else
    {
      size = NSMakeSize(floor(natural.width * _zoom),
                        floor(natural.height * _zoom));
    }
  /* Filling the visible area keeps the scroll view's background out of sight */
  [self setFrameSize: NSMakeSize(MAX(size.width, [scroll contentSize].width),
                                 MAX(size.height, [scroll contentSize].height))];
  _bedRect = NSMakeRect(floor((NSWidth([self bounds]) - size.width) / 2),
                        floor((NSHeight([self bounds]) - size.height) / 2),
                        size.width, size.height);
  [self setNeedsDisplay: YES];
}

- (CGFloat) currentScale
{
  NSSize natural = [self naturalSize];

  return (natural.width > 0) ? NSWidth(_bedRect) / natural.width : 1;
}

- (void) zoomIn
{
  _zoom = [self currentScale] * 1.25;
  [self updateSize];
}

- (void) zoomOut
{
  _zoom = [self currentScale] / 1.25;
  [self updateSize];
}

- (void) zoomToFit
{
  _zoom = 0;
  [self updateSize];
}

- (void) setImage: (NSImage *)image
{
  _image = image;
  [self updateSize];
}

- (void) setBedAspect: (NSSize)aspect
{
  _bedAspect = aspect;
  [self updateSize];
}

#pragma mark Selections

- (NSArray *) selections
{
  return [_selections copy];
}

- (void) setSelections: (NSArray *)selections
{
  _selections = [selections mutableCopy];
  _active = [_selections count] > 0 ? (NSInteger)[_selections count] - 1 : -1;
  [self setNeedsDisplay: YES];
}

- (NSInteger) activeSelection
{
  return _active;
}

- (void) changed
{
  [self setNeedsDisplay: YES];
  [_delegate previewViewSelectionsDidChange: self];
}

- (void) addSelection: (NSRect)fraction
{
  [_selections addObject: [NSValue valueWithRect: fraction]];
  _active = [_selections count] - 1;
  [self changed];
}

- (void) setActiveSelectionRect: (NSRect)fraction
{
  if (_active < 0)
    {
      [self addSelection: fraction];
      return;
    }
  [_selections replaceObjectAtIndex: _active
                         withObject: [NSValue valueWithRect: fraction]];
  [self changed];
}

- (void) removeActiveSelection
{
  if (_active < 0)
    {
      return;
    }
  [_selections removeObjectAtIndex: _active];
  _active = (NSInteger)[_selections count] - 1;
  [self changed];
}

- (void) removeAllSelections
{
  [_selections removeAllObjects];
  _active = -1;
  [self changed];
}

- (NSRect) selectionAtIndex: (NSInteger)i
{
  return [[_selections objectAtIndex: i] rectValue];
}

#pragma mark Drawing

- (void) drawHandlesForRect: (NSRect)r
{
  CGFloat xs[3] = {NSMinX(r), NSMidX(r), NSMaxX(r)};
  CGFloat ys[3] = {NSMinY(r), NSMidY(r), NSMaxY(r)};
  int i, j;

  for (i = 0; i < 3; i++)
    {
      for (j = 0; j < 3; j++)
        {
          NSRect h;

          if (i == 1 && j == 1)
            {
              continue;
            }
          h = NSMakeRect(floor(xs[i]) - 2.5, floor(ys[j]) - 2.5, 6, 6);
          [[NSColor whiteColor] set];
          NSRectFill(h);
          [[NSColor blackColor] set];
          NSFrameRect(h);
        }
    }
}

- (void) drawRect: (NSRect)dirty
{
  NSRect bed = [self bedRect];
  NSInteger i;

  [[NSColor colorWithCalibratedWhite: 0.85 alpha: 1] set];
  NSRectFill(dirty);
  if (_image != nil)
    {
      [_image drawInRect: bed fromRect: NSZeroRect
               operation: NSCompositeSourceOver fraction: 1.0];
    }
  else
    {
      [[NSColor whiteColor] set];
      NSRectFill(bed);
    }

  if ([_selections count] == 0)
    {
      return;
    }

  /*
   * Dimming what is outside makes it obvious what will be scanned. The
   * selections are drawn again undimmed on top, which stays right where
   * they overlap (an even-odd path would dim overlaps twice).
   */
  [[NSColor colorWithCalibratedWhite: 0 alpha: 0.35] set];
  NSRectFillUsingOperation(bed, NSCompositeSourceOver);
  for (i = 0; i < (NSInteger)[_selections count]; i++)
    {
      NSRect f = [self selectionAtIndex: i];
      NSRect r = [self viewRectForFraction: f];

      if (_image != nil)
        {
          NSSize n = [_image size];
          /* The image's own coordinates are y-up, the fractions top-down */
          NSRect src = NSMakeRect(NSMinX(f) * n.width,
                                  (1 - NSMaxY(f)) * n.height,
                                  NSWidth(f) * n.width, NSHeight(f) * n.height);

          [_image drawInRect: r fromRect: src
                   operation: NSCompositeCopy fraction: 1.0];
        }
      else
        {
          [[NSColor whiteColor] set];
          NSRectFill(r);
        }
    }

  for (i = 0; i < (NSInteger)[_selections count]; i++)
    {
      NSRect r = NSInsetRect([self viewRectForFraction: [self selectionAtIndex: i]],
                             0.5, 0.5);
      NSBezierPath *path = [NSBezierPath bezierPathWithRect: r];
      CGFloat dash[2] = {4, 3};

      [[NSColor whiteColor] set];
      [path setLineWidth: 1];
      [path stroke];
      [path setLineDash: dash count: 2 phase: 0];
      [(i == _active) ? [NSColor selectedControlColor] : [NSColor blackColor] set];
      [path stroke];
      if (i == _active)
        {
          [self drawHandlesForRect: r];
        }
    }
}

#pragma mark Mouse

- (unsigned) edgesAtPoint: (NSPoint)p ofRect: (NSRect)r
{
  unsigned edges = 0;
  BOOL withinX = p.x >= NSMinX(r) - SCHandleSize && p.x <= NSMaxX(r) + SCHandleSize;
  BOOL withinY = p.y >= NSMinY(r) - SCHandleSize && p.y <= NSMaxY(r) + SCHandleSize;

  if (!withinX || !withinY)
    {
      return 0;
    }
  if (fabs(p.x - NSMinX(r)) <= SCHandleSize)
    {
      edges |= SCEdgeLeft;
    }
  else if (fabs(p.x - NSMaxX(r)) <= SCHandleSize)
    {
      edges |= SCEdgeRight;
    }
  if (fabs(p.y - NSMinY(r)) <= SCHandleSize)
    {
      edges |= SCEdgeTop;
    }
  else if (fabs(p.y - NSMaxY(r)) <= SCHandleSize)
    {
      edges |= SCEdgeBottom;
    }
  return edges;
}

- (NSInteger) selectionAtPoint: (NSPoint)p
{
  NSInteger i;

  /* Topmost first: the last one drawn wins */
  for (i = (NSInteger)[_selections count] - 1; i >= 0; i--)
    {
      if (NSPointInRect(p, [self viewRectForFraction: [self selectionAtIndex: i]]))
        {
          return i;
        }
    }
  return -1;
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSInteger hit;

  [[self window] makeFirstResponder: self];
  _dragStart = p;
  _drag = SCDragCreate;

  if (_active >= 0)
    {
      NSRect r = [self viewRectForFraction: [self selectionAtIndex: _active]];

      _edges = [self edgesAtPoint: p ofRect: r];
      if (_edges != 0)
        {
          _drag = SCDragResize;
          _dragOriginal = [self selectionAtIndex: _active];
          return;
        }
    }
  hit = [self selectionAtPoint: p];
  if (hit >= 0)
    {
      _active = hit;
      _drag = SCDragMove;
      _dragOriginal = [self selectionAtIndex: hit];
      [self setNeedsDisplay: YES];
    }
}

- (void) mouseDragged: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSPoint f0 = [self fractionForPoint: _dragStart];
  NSPoint f1 = [self fractionForPoint: p];
  NSRect r;

  [self autoscroll: event];
  switch (_drag)
    {
      case SCDragCreate:
        if (fabs(p.x - _dragStart.x) < SCMinimumDrag
            && fabs(p.y - _dragStart.y) < SCMinimumDrag)
          {
            return;
          }
        r = NSMakeRect(MIN(f0.x, f1.x), MIN(f0.y, f1.y),
                       fabs(f1.x - f0.x), fabs(f1.y - f0.y));
        [_selections addObject: [NSValue valueWithRect: r]];
        _active = [_selections count] - 1;
        _dragOriginal = r;
        /* From here on the new selection is resized by its far corner */
        _drag = SCDragResize;
        _edges = ((f1.x < f0.x) ? SCEdgeLeft : SCEdgeRight)
          | ((f1.y < f0.y) ? SCEdgeTop : SCEdgeBottom);
        _dragStart = p;
        break;

      case SCDragMove:
        r = _dragOriginal;
        r.origin.x = MIN(1 - NSWidth(r), MAX(0, NSMinX(r) + f1.x - f0.x));
        r.origin.y = MIN(1 - NSHeight(r), MAX(0, NSMinY(r) + f1.y - f0.y));
        [_selections replaceObjectAtIndex: _active
                               withObject: [NSValue valueWithRect: r]];
        break;

      case SCDragResize:
        {
          CGFloat x0 = NSMinX(_dragOriginal), x1 = NSMaxX(_dragOriginal);
          CGFloat y0 = NSMinY(_dragOriginal), y1 = NSMaxY(_dragOriginal);
          CGFloat dx = f1.x - f0.x, dy = f1.y - f0.y;

          if (_edges & SCEdgeLeft)   { x0 += dx; }
          if (_edges & SCEdgeRight)  { x1 += dx; }
          if (_edges & SCEdgeTop)    { y0 += dy; }
          if (_edges & SCEdgeBottom) { y1 += dy; }
          x0 = MIN(1, MAX(0, x0));
          x1 = MIN(1, MAX(0, x1));
          y0 = MIN(1, MAX(0, y0));
          y1 = MIN(1, MAX(0, y1));
          r = NSMakeRect(MIN(x0, x1), MIN(y0, y1), fabs(x1 - x0), fabs(y1 - y0));
          [_selections replaceObjectAtIndex: _active
                                 withObject: [NSValue valueWithRect: r]];
        }
        break;

      default:
        return;
    }
  [self setNeedsDisplay: YES];
}

- (void) mouseUp: (NSEvent *)event
{
  SCDragMode mode = _drag;

  _drag = SCDragNone;
  if (mode == SCDragCreate)
    {
      /* A click on the empty bed only deselects */
      _active = -1;
      [self setNeedsDisplay: YES];
      return;
    }
  if (_active >= 0)
    {
      NSRect r = [self viewRectForFraction: [self selectionAtIndex: _active]];

      /* A selection dragged down to nothing is gone */
      if (NSWidth(r) < 2 || NSHeight(r) < 2)
        {
          [_selections removeObjectAtIndex: _active];
          _active = -1;
        }
    }
  [self changed];
}

- (void) keyDown: (NSEvent *)event
{
  unichar c = [[event charactersIgnoringModifiers] length] > 0
    ? [[event charactersIgnoringModifiers] characterAtIndex: 0] : 0;

  if (c == NSDeleteCharacter || c == NSBackspaceCharacter
      || c == NSDeleteFunctionKey)
    {
      [self removeActiveSelection];
      return;
    }
  [super keyDown: event];
}

- (void) delete: (id)sender
{
  [self removeActiveSelection];
}

@end
