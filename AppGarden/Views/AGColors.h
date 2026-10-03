/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef AG_COLORS_H
#define AG_COLORS_H

#import <AppKit/AppKit.h>

/*
 * The one place a literal color value may be written. Every other color the
 * app draws comes from the theme (windowBackgroundColor, controlBackgroundColor,
 * textColor, disabledControlTextColor, gridColor, and selectedControlColor as
 * the accent), so the interface follows whatever appearance the desktop has
 * instead of hard-coding a hue.
 */

/* Hairline border of cards, screenshots and the placeholder tile: black at 8
 * percent, so it separates from the background without drawing a box. */
static inline NSColor *AGCardBorderColor(void)
{
  return [NSColor colorWithCalibratedWhite:0.0 alpha:0.08];
}

/* Behind a letterboxed screenshot, so an image whose ratio differs from the
 * frame reads as a photograph on a mount rather than as a rendering bug. */
static inline NSColor *AGScreenshotLetterboxColor(void)
{
  return [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
}

/* The "showing the cached catalog" banner: pale yellow under dark text. */
static inline NSColor *AGBannerBackgroundColor(void)
{
  return [NSColor colorWithCalibratedRed:1.0 green:0.96 blue:0.80 alpha:1.0];
}

/* Placeholder icon gradient, lighter at the top. */
static inline NSColor *AGPlaceholderGradientTopColor(void)
{
  return [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
}

static inline NSColor *AGPlaceholderGradientBottomColor(void)
{
  return [NSColor colorWithCalibratedWhite:0.84 alpha:1.0];
}

/* Under the placeholder's letter, so white text survives the light gradient. */
static inline NSColor *AGPlaceholderLetterShadowColor(void)
{
  return [NSColor colorWithCalibratedWhite:0.0 alpha:0.15];
}

/* The placeholder's letter itself. */
static inline NSColor *AGPlaceholderLetterColor(void)
{
  return [NSColor whiteColor];
}

/* The single accent, borrowed from the theme's selection color. */
static inline NSColor *AGAccentColor(void)
{
  return [NSColor selectedControlColor];
}

#endif /* AG_COLORS_H */
