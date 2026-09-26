/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/*
 * The rich, skeuomorphic look (wood sidebar, leather/paper task list,
 * carved headings) is drawn in code with NSBezierPath and NSGradient
 * rather than shipped as bitmaps, so it stays crisp at every
 * GSScaleFactor and needs no bundled art.
 */
@interface TDTexture : NSObject

/* A vertically grained wood panel, as used behind the list sidebar. */
+ (void)paintWoodGrainInRect: (NSRect)rect;

/* A warm stitched-leather / parchment panel, as used behind the task
 * list. */
+ (void)paintLeatherInRect: (NSRect)rect;

/* A subtle selection bar in the given tint, replacing the flat platform
 * blue highlight so a selected row still reads as part of the material. */
+ (void)paintSelectionInRect: (NSRect)rect tint: (NSColor *)tint;

/* Carves (or embosses) a title into the material: a dark, slightly
 * offset shadow below the glyphs and a light highlight above, so the
 * text reads as pressed into the wood/leather rather than painted flat. */
+ (void)drawEmbossedString: (NSString *)string
                     inRect: (NSRect)rect
                       font: (NSFont *)font
                      color: (NSColor *)color
                  alignment: (NSTextAlignment)alignment;

/* A five-point star, filled when important, outlined otherwise; used for
 * both the toggle button image and any other star drawn in code. */
+ (NSImage *)starImageFilled: (BOOL)filled size: (NSSize)size;

@end
