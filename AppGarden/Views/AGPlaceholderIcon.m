/* Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause */

#import "AGPlaceholderIcon.h"
#import "AGColors.h"

@implementation AGPlaceholderIcon

/* Corner radius 22 and a 40 pt letter are the spec's values for a 96-point
 * tile; every other size asks for (and gets) the same proportions, so a
 * 128-point detail-page icon is the same drawing scaled up rather than a
 * second design. */
static const CGFloat kAGPlaceholderTileRef = 96.0;
static const CGFloat kAGPlaceholderCornerRef = 22.0;
static const CGFloat kAGPlaceholderLetterRef = 40.0;
/* Part of the tile a letter may occupy before it is shrunk. Leaves the
 * rounded corners clear for an initial from a wide script. */
static const CGFloat kAGPlaceholderLetterSlack = 0.76;

+ (NSImage *)placeholderIconForDisplayName:(NSString *)displayName size:(CGFloat)size
{
  if (size < 4.0)
    return nil;

  NSString *letter = [self letterForDisplayName:displayName];

  /* Cards redraw on every hover and scroll and there are hundreds of them, so
   * the rendered artwork is memoized on the two things it depends on. */
  static NSCache *cache = nil;
  if (cache == nil)
    {
      cache = [[NSCache alloc] init];
      [cache setCountLimit:128];
    }

  NSString *key = [NSString stringWithFormat:@"%@|%.2f", letter, size];
  NSImage *cached = [cache objectForKey:key];
  if (cached != nil)
    return cached;

  /*
   * The tile is rendered through the image's own focus, not into a bitmap
   * representation. A graphics context built from a bitmap representation has
   * no drawing surface in this stack: a fill drawn into one never reaches the
   * pixels, so the tile would come out empty and every card would show a
   * blank square. Focus gives the drawing a real surface; it costs one
   * offscreen server window per rendered tile, which is exactly what the
   * cache above is for - the grid only ever asks for the tiles it shows.
   */
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
  [image lockFocus];
  [self drawTileOfSize:size letter:letter];
  [image unlockFocus];

  /* Focus that never attached leaves an image with no representation, and an
   * empty picture is worse than none: the caller then draws nothing at all. */
  if ([[image representations] count] == 0)
    return nil;

  [cache setObject:image forKey:key];
  return image;
}

/* Drawn in the image's own coordinate system, so every value below is in
 * points on the finished tile. */
+ (void)drawTileOfSize:(CGFloat)size letter:(NSString *)letter
{
  NSRect tile = NSMakeRect(0.0, 0.0, size, size);
  CGFloat radius = size * (kAGPlaceholderCornerRef / kAGPlaceholderTileRef);
  NSBezierPath *shape =
      [NSBezierPath bezierPathWithRoundedRect:tile xRadius:radius yRadius:radius];

  /* Angle 90 runs bottom to top, so the darker stop lands at the base and the
   * tile has a subtle top-lit feel instead of a flat fill. */
  NSGradient *gradient = [[NSGradient alloc]
      initWithStartingColor:AGPlaceholderGradientBottomColor()
                endingColor:AGPlaceholderGradientTopColor()];
  [gradient drawInBezierPath:shape angle:90.0];

  [shape setLineWidth:1.0];
  [AGCardBorderColor() setStroke];
  [shape stroke];

  /* Measured first so the letter is optically centred in the tile without
   * trusting a paragraph layout inside a tiny square. */
  CGFloat fontSize = size * (kAGPlaceholderLetterRef / kAGPlaceholderTileRef);
  NSFont *font = [NSFont boldSystemFontOfSize:fontSize];
  if (font == nil)
    return;

  NSDictionary *attributes = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : AGPlaceholderLetterColor(),
    NSShadowAttributeName : [self letterShadow]
  };
  NSSize measured = [letter sizeWithAttributes:attributes];

  /* An initial from a script whose glyphs are wider or taller than Latin ones
   * would touch the rounded corner, so shrink it once to fit. */
  CGFloat slack = size * kAGPlaceholderLetterSlack;
  if (measured.width > slack || measured.height > slack)
    {
      CGFloat fit = fontSize * MIN(slack / MAX(measured.width, 1.0),
                                   slack / MAX(measured.height, 1.0));
      NSFont *smaller = [NSFont boldSystemFontOfSize:fit];
      if (smaller != nil)
        {
          attributes = @{
            NSFontAttributeName : smaller,
            NSForegroundColorAttributeName : AGPlaceholderLetterColor(),
            NSShadowAttributeName : [self letterShadow]
          };
          measured = [letter sizeWithAttributes:attributes];
        }
    }

  NSPoint origin = NSMakePoint(floor((size - measured.width) / 2.0),
                               floor((size - measured.height) / 2.0));
  /* The tile is square, so this anchor centres the glyph whether the surface
   * reports flipped or unflipped. */
  [letter drawAtPoint:origin withAttributes:attributes];
}

/* The first composed character, taken as written: a name beginning in a lower
 * case letter keeps it, and a name in another script keeps its own initial.
 * Composed-character range matters so an accented letter or a surrogate pair
 * is never cut in half. */
+ (NSString *)letterForDisplayName:(NSString *)displayName
{
  if (displayName == nil || [displayName length] == 0)
    return @"?";
  NSRange first = [displayName rangeOfComposedCharacterSequenceAtIndex:0];
  if (first.location == NSNotFound)
    return @"?";
  return [displayName substringWithRange:first];
}

/* One shadow for every icon: a soft dark offset that keeps a white letter
 * legible over the pale gradient at any size the cards ask for. */
+ (NSShadow *)letterShadow
{
  static NSShadow *shadow = nil;
  if (shadow == nil)
    {
      shadow = [[NSShadow alloc] init];
      [shadow setShadowColor:AGPlaceholderLetterShadowColor()];
      [shadow setShadowOffset:NSMakeSize(0.0, -1.0)];
      [shadow setShadowBlurRadius:1.0];
    }
  return shadow;
}

@end
