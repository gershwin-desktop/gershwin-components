/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Highlighted extra icons follow the highlighted title color and stay sharp
   at every scale factor.  Headless: run from this directory.  A real
   NSMenuItemCell needs fonts and so a display, so the cell calling into the
   image swap is left to the live check. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#include "../../TintedMenuItemCell.m"

/* YES when every pixel of tinted has color and the alpha of the same pixel
   in source. */
static BOOL PixelsAreTinted(NSBitmapImageRep *source, NSBitmapImageRep *tinted,
                            NSColor *color)
{
  NSColor *want = [color colorUsingColorSpaceName: NSDeviceRGBColorSpace];
  const CGFloat tolerance = 2.0 / 255.0;

  if ([source pixelsWide] != [tinted pixelsWide]
      || [source pixelsHigh] != [tinted pixelsHigh])
    return NO;

  for (NSInteger y = 0; y < [source pixelsHigh]; y++)
    {
      for (NSInteger x = 0; x < [source pixelsWide]; x++)
        {
          NSColor *s = [source colorAtX: x y: y];
          NSColor *t = [[tinted colorAtX: x y: y]
                         colorUsingColorSpaceName: NSDeviceRGBColorSpace];
          if (fabs([t alphaComponent] - [s alphaComponent]) > tolerance)
            return NO;
          if ([t alphaComponent] > 0.5
              && (fabs([t redComponent] - [want redComponent]) > tolerance
                  || fabs([t greenComponent] - [want greenComponent]) > tolerance
                  || fabs([t blueComponent] - [want blueComponent]) > tolerance))
            return NO;
        }
    }
  return YES;
}

int main(void)
{
  @autoreleasepool
    {
      NSColor *white = [NSColor colorWithDeviceRed: 1 green: 1 blue: 1 alpha: 1];
      NSColor *highlight = [NSColor selectedMenuItemTextColor];
      NSImage *icon = [[NSImage alloc]
                        initWithContentsOfFile: @"../../Resources/Icons/cpu.tiff"];
      NSSize iconSize = NSMakeSize(18, 18);
      [icon setSize: iconSize];
      NSArray *iconReps = [icon representations];

      START_SET("tinted copy keeps every scale")
        NSImage *tinted = TintedMenuImage(icon, white);
        NSArray *reps = [tinted representations];
        PASS([reps count] == 2, "both the 1x and the 2x rep are tinted");
        PASS([[reps objectAtIndex: 0] pixelsWide] == 18
             && [[reps objectAtIndex: 1] pixelsWide] == 36,
             "reps keep their pixel sizes");
        PASS(NSEqualSizes([[reps objectAtIndex: 1] size], iconSize),
             "the 2x rep still covers 18x18 points");
        PASS(NSEqualSizes([tinted size], iconSize),
             "the tinted image has the icon's size");
        PASS(PixelsAreTinted([iconReps objectAtIndex: 0],
                             [reps objectAtIndex: 0], white)
             && PixelsAreTinted([iconReps objectAtIndex: 1],
                                [reps objectAtIndex: 1], white),
             "every pixel takes the tint color with the icon's alpha");
      END_SET("tinted copy keeps every scale")

      START_SET("highlighted menu bar items")
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: @"30%"
                                                      action: NULL
                                               keyEquivalent: @""];
        [item setImage: icon];

        UpdateHighlightedItemImage(item, YES);
        NSImage *shown = [item image];
        PASS(shown != icon, "an item with a title shows a tinted icon");
        PASS([[shown representations] count] == 2,
             "the shown icon keeps both reps");
        PASS(PixelsAreTinted([iconReps objectAtIndex: 1],
                             [[shown representations] objectAtIndex: 1],
                             highlight),
             "the shown icon has the highlighted title color");

        UpdateHighlightedItemImage(item, YES);
        PASS([item image] == shown,
             "highlighting again does not tint the tinted icon");

        UpdateHighlightedItemImage(item, NO);
        PASS([item image] == icon, "unhighlighting restores the original icon");

        UpdateHighlightedItemImage(item, NO);
        PASS([item image] == icon, "unhighlighting again changes nothing");

        UpdateHighlightedItemImage(item, YES);
        NSImage *replacement = [[NSImage alloc] initWithSize: iconSize];
        [item setImage: replacement];
        UpdateHighlightedItemImage(item, NO);
        PASS([item image] == replacement,
             "an icon set while highlighted is not overwritten");
      END_SET("highlighted menu bar items")

      START_SET("menu bar icons updated by an extra")
        NSImage *update = [[NSImage alloc]
                            initWithContentsOfFile: @"../../Resources/Icons/ram.tiff"];
        [update setSize: iconSize];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: @"30%"
                                                      action: NULL
                                               keyEquivalent: @""];

        [item setMenuBarImage: icon];
        PASS([item image] == icon, "an unhighlighted item shows the icon as is");

        UpdateHighlightedItemImage(item, YES);
        [item setMenuBarImage: update];
        NSImage *shown = [item image];
        PASS(shown != update,
             "an icon updated while highlighted is shown tinted");
        PASS(PixelsAreTinted([[update representations] objectAtIndex: 0],
                             [[shown representations] objectAtIndex: 0],
                             highlight),
             "the updated icon has the highlighted title color");

        UpdateHighlightedItemImage(item, NO);
        PASS([item image] == update,
             "unhighlighting shows the updated icon, not the one before");

        UpdateHighlightedItemImage(item, YES);
        [item setMenuBarImage: nil];
        PASS([item image] == nil, "an extra can remove its icon while highlighted");
        UpdateHighlightedItemImage(item, NO);
      END_SET("menu bar icons updated by an extra")
    }
  return 0;
}
