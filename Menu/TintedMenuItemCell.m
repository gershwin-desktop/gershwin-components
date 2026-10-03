/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TintedMenuItemCell.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static const char kUntintedImageKey;

/* Extra icons are monochrome, so a highlighted one is redrawn in the
   highlighted title color.  Each rep is tinted on its own so the icon stays
   sharp at every scale factor; going through TIFF also turns icons that were
   drawn at runtime into bitmaps. */
static NSImage *TintedMenuImage(NSImage *image, NSColor *color)
{
  NSColor *rgb = [color colorUsingColorSpaceName: NSDeviceRGBColorSpace];
  NSArray *reps = [NSBitmapImageRep imageRepsWithData: [image TIFFRepresentation]];
  NSImage *tinted = [[NSImage alloc] initWithSize: [image size]];

  for (NSBitmapImageRep *source in reps)
    {
      NSInteger width = [source pixelsWide];
      NSInteger height = [source pixelsHigh];
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes: NULL
                      pixelsWide: width
                      pixelsHigh: height
                   bitsPerSample: 8
                 samplesPerPixel: 4
                        hasAlpha: YES
                        isPlanar: NO
                  colorSpaceName: NSDeviceRGBColorSpace
                     bytesPerRow: 0
                    bitsPerPixel: 0];

      for (NSInteger y = 0; y < height; y++)
        {
          for (NSInteger x = 0; x < width; x++)
            {
              CGFloat alpha = [[source colorAtX: x y: y] alphaComponent];
              [rep setColor: [rgb colorWithAlphaComponent: [rgb alphaComponent] * alpha]
                        atX: x
                          y: y];
            }
        }
      [rep setSize: [source size]];
      [tinted addRepresentation: rep];
    }
  return tinted;
}

/* Named icons are shared between all items showing them, so their tinted
   copies are shared too.  The tinted copy remembers its original so that
   unhighlighting can tell it apart from an icon the extra set meanwhile. */
static NSImage *HighlightedImage(NSImage *image)
{
  static NSMutableDictionary *cache = nil;
  NSString *name = [image name];
  NSImage *tinted = (name != nil) ? [cache objectForKey: name] : nil;

  if (tinted == nil)
    {
      tinted = TintedMenuImage(image, [NSColor selectedMenuItemTextColor]);
      objc_setAssociatedObject(tinted, &kUntintedImageKey, image,
                               OBJC_ASSOCIATION_RETAIN);
      if (name != nil)
        {
          if (cache == nil)
            cache = [NSMutableDictionary new];
          [cache setObject: tinted forKey: name];
        }
    }
  return tinted;
}

static const char kHighlightedKey;

/* An icon that is already tinted is left alone, so a missed unhighlight can
   never leave it stuck in the highlight color; an icon set behind our back
   while highlighted is not replaced by the stale original. */
static void UpdateHighlightedItemImage(NSMenuItem *item, BOOL highlighted)
{
  NSImage *image = [item image];
  NSImage *untinted = (image != nil)
    ? objc_getAssociatedObject(image, &kUntintedImageKey) : nil;

  /* Extras refresh their icons while their menu is open; remembering the
     state lets -setMenuBarImage: keep those icons in the highlight color. */
  objc_setAssociatedObject(item, &kHighlightedKey,
                           highlighted ? [NSNumber numberWithBool: YES] : nil,
                           OBJC_ASSOCIATION_RETAIN);

  /* Only a named image is one of ours: the extras register their icons by
     name, and those are the monochrome ones a highlight colour suits. An
     application's icon comes from the workspace without a name, is in full
     colour, and must be left as it is - tinting it would flatten it to a
     silhouette, and getting at its pixels means building a bitmap of the
     whole icon that the icon then keeps for good. */
  if (highlighted && image != nil && untinted == nil && [image name] != nil)
    [item setImage: HighlightedImage(image)];
  else if (!highlighted && untinted != nil)
    [item setImage: untinted];
}

@implementation NSMenuItem (TintedIcons)

- (void) setMenuBarImage: (NSImage *)image
{
  if (image != nil && [image name] != nil
      && objc_getAssociatedObject(self, &kHighlightedKey) != nil)
    image = HighlightedImage(image);
  [self setImage: image];
}

@end

@implementation NSMenuItemCell (TintedIcons)

/* The theme draws menu images itself instead of going through
   -drawImage:withFrame:inView:, so the tinted icon has to be the item's
   image while its cell is highlighted. */
+ (void) load
{
  method_exchangeImplementations(
    class_getInstanceMethod(self, @selector(setHighlighted:)),
    class_getInstanceMethod(self, @selector(tinted_setHighlighted:)));
}

- (void) tinted_setHighlighted: (BOOL)flag
{
  BOOL wasHighlighted = [self isHighlighted];

  [self tinted_setHighlighted: flag];

  /* Every image in Menu's menus is a monochrome extra icon, in the menu bar
     and in the extras' own menus; imported application menus carry none. */
  if (flag != wasHighlighted)
    UpdateHighlightedItemImage([self menuItem], flag);
}

@end
