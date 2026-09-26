/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DKTexture.h"
#import <math.h>

@implementation DKTexture

+ (void)paintWoodGrainInRect: (NSRect)rect
{
  NSColor *top = [NSColor colorWithCalibratedRed: 0.42 green: 0.27 blue: 0.14 alpha: 1.0];
  NSColor *bottom = [NSColor colorWithCalibratedRed: 0.27 green: 0.16 blue: 0.08 alpha: 1.0];
  NSGradient *base = [[[NSGradient alloc] initWithStartingColor: top endingColor: bottom] autorelease];
  CGFloat y;
  CGFloat lineIndex = 0;

  [base drawInRect: rect angle: 90.0];

  /* Grain: thin, gently wavy horizontal strokes at varying darkness, the
   * way a plank's growth rings read once planed flat. */
  [NSGraphicsContext saveGraphicsState];
  [NSBezierPath clipRect: rect];
  for (y = rect.origin.y + 3.0; y < NSMaxY(rect); y += 5.0)
    {
      CGFloat alpha = 0.05 + 0.05 * fabs(sin(lineIndex * 0.7));
      NSBezierPath *grain = [NSBezierPath bezierPath];
      CGFloat x;

      [[NSColor colorWithCalibratedWhite: 0.0 alpha: alpha] set];
      [grain setLineWidth: 1.0];
      [grain moveToPoint: NSMakePoint(rect.origin.x, y)];
      for (x = rect.origin.x; x <= NSMaxX(rect); x += 14.0)
        {
          CGFloat wobble = 1.5 * sin((x + lineIndex * 37.0) * 0.05);
          [grain lineToPoint: NSMakePoint(x, y + wobble)];
        }
      [grain stroke];
      lineIndex += 1.0;
    }

  /* Plank seams: a light/dark pair every ~96px, like separate boards. */
  for (y = rect.origin.y; y < NSMaxY(rect); y += 96.0)
    {
      [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.35] set];
      [NSBezierPath strokeLineFromPoint: NSMakePoint(rect.origin.x, y)
                                 toPoint: NSMakePoint(NSMaxX(rect), y)];
      [[NSColor colorWithCalibratedWhite: 1.0 alpha: 0.08] set];
      [NSBezierPath strokeLineFromPoint: NSMakePoint(rect.origin.x, y + 1.0)
                                 toPoint: NSMakePoint(NSMaxX(rect), y + 1.0)];
    }
  [NSGraphicsContext restoreGraphicsState];
}

+ (void)paintLeatherInRect: (NSRect)rect
{
  NSColor *center = [NSColor colorWithCalibratedRed: 0.94 green: 0.88 blue: 0.76 alpha: 1.0];
  NSColor *edge = [NSColor colorWithCalibratedRed: 0.84 green: 0.76 blue: 0.60 alpha: 1.0];
  NSGradient *vignette = [[[NSGradient alloc] initWithStartingColor: center endingColor: edge] autorelease];
  NSBezierPath *stitch;
  CGFloat dash[2] = { 3.0, 3.0 };
  NSRect inset = NSInsetRect(rect, 6.0, 6.0);

  [vignette drawInRect: rect relativeCenterPosition: NSMakePoint(0.0, 0.35)];

  if (inset.size.width <= 0.0 || inset.size.height <= 0.0)
    {
      return;
    }

  stitch = [NSBezierPath bezierPathWithRect: inset];
  [stitch setLineWidth: 1.0];
  [stitch setLineDash: dash count: 2 phase: 0.0];
  [[NSColor colorWithCalibratedRed: 0.55 green: 0.42 blue: 0.28 alpha: 0.5] set];
  [stitch stroke];
}

+ (void)paintSelectionInRect: (NSRect)rect tint: (NSColor *)tint
{
  NSColor *light = [tint colorWithAlphaComponent: 0.85];
  NSColor *dark = [tint colorWithAlphaComponent: 0.55];
  NSGradient *grad = [[[NSGradient alloc] initWithStartingColor: light endingColor: dark] autorelease];

  [grad drawInRect: rect angle: 90.0];
  [[NSColor colorWithCalibratedWhite: 0.0 alpha: 0.25] set];
  [NSBezierPath strokeLineFromPoint: NSMakePoint(rect.origin.x, NSMaxY(rect) - 0.5)
                             toPoint: NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 0.5)];
  [NSBezierPath strokeLineFromPoint: NSMakePoint(rect.origin.x, rect.origin.y + 0.5)
                             toPoint: NSMakePoint(NSMaxX(rect), rect.origin.y + 0.5)];
}

+ (void)drawEmbossedString: (NSString *)string
                     inRect: (NSRect)rect
                       font: (NSFont *)font
                      color: (NSColor *)color
                  alignment: (NSTextAlignment)alignment
{
  NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys: font, NSFontAttributeName, nil];
  NSSize size = [string sizeWithAttributes: attrs];
  CGFloat x;
  NSPoint origin;

  if (alignment == NSRightTextAlignment)
    {
      x = NSMaxX(rect) - size.width;
    }
  else if (alignment == NSCenterTextAlignment)
    {
      x = rect.origin.x + (rect.size.width - size.width) / 2.0;
    }
  else
    {
      x = rect.origin.x;
    }
  origin = NSMakePoint(x, rect.origin.y + (rect.size.height - size.height) / 2.0);

  {
    NSDictionary *shadowAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
      font, NSFontAttributeName,
      [NSColor colorWithCalibratedWhite: 0.0 alpha: 0.35], NSForegroundColorAttributeName,
      nil];
    [string drawAtPoint: NSMakePoint(origin.x, origin.y - 1.0) withAttributes: shadowAttrs];
  }
  {
    NSDictionary *highlightAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
      font, NSFontAttributeName,
      [NSColor colorWithCalibratedWhite: 1.0 alpha: 0.45], NSForegroundColorAttributeName,
      nil];
    [string drawAtPoint: NSMakePoint(origin.x, origin.y + 1.0) withAttributes: highlightAttrs];
  }
  {
    NSDictionary *mainAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
      font, NSFontAttributeName,
      color, NSForegroundColorAttributeName,
      nil];
    [string drawAtPoint: origin withAttributes: mainAttrs];
  }
}

+ (NSImage *)starImageFilled: (BOOL)filled size: (NSSize)size
{
  NSImage *image = [[[NSImage alloc] initWithSize: size] autorelease];
  NSBezierPath *star = [NSBezierPath bezierPath];
  CGFloat cx = size.width / 2.0;
  CGFloat cy = size.height / 2.0;
  CGFloat outerR = MIN(cx, cy) - 1.0;
  CGFloat innerR = outerR * 0.42;
  NSInteger i;

  [image lockFocus];
  for (i = 0; i < 10; i++)
    {
      CGFloat r = (i % 2 == 0) ? outerR : innerR;
      CGFloat angle = (M_PI / 2.0) + (i * M_PI / 5.0);
      NSPoint p = NSMakePoint(cx + r * cos(angle), cy + r * sin(angle));

      if (i == 0)
        {
          [star moveToPoint: p];
        }
      else
        {
          [star lineToPoint: p];
        }
    }
  [star closePath];

  if (filled)
    {
      [[NSColor colorWithCalibratedRed: 0.85 green: 0.62 blue: 0.12 alpha: 1.0] set];
      [star fill];
      [[NSColor colorWithCalibratedRed: 0.55 green: 0.38 blue: 0.05 alpha: 1.0] set];
      [star setLineWidth: 0.75];
      [star stroke];
    }
  else
    {
      [[NSColor colorWithCalibratedWhite: 0.55 alpha: 0.9] set];
      [star setLineWidth: 1.0];
      [star stroke];
    }
  [image unlockFocus];
  return image;
}

@end
