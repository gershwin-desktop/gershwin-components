/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/*
 * The generic application icon, drawn in code: a rounded square with a soft
 * vertical gradient, a hairline border and the display name's first letter in
 * white. Deliberately better than one generic glyph: a grid of hundreds of
 * apps without icons stays readable because every card still shows its name
 * as a big letter.
 */
@interface AGPlaceholderIcon : NSObject

/*
 * A size x size image (96 on cards, 128 on the detail page), rendered once
 * and cached per letter and per size: cards redraw on every hover and scroll,
 * and re-rendering the artwork each time would be wasted work. displayName
 * may be nil, in which case the letter is a question mark.
 */
+ (NSImage *)placeholderIconForDisplayName:(NSString *)displayName size:(CGFloat)size;

@end
