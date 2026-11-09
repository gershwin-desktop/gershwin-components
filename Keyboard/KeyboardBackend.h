/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* How the Keyboard preference pane puts a layout onto the running X server,
 * shared with gershwin-apply-settings so the layout the user chose is put
 * back the same way at every login.  Built as libKeyboardBackend
 * (Libraries/KeyboardBackend) under ARC; objects handed out are autoreleased
 * from the caller's point of view. */
@interface KeyboardBackend : NSObject

/* The setxkbmap binary, or nil when none is installed. */
+ (NSString *)findSetxkbmap;

/* Clears all XKB options first, because setxkbmap -option only ever adds to
 * the options already loaded; an empty variant or options string is left
 * out.  On failure *error holds setxkbmap's stderr. */
+ (BOOL)applyLayout:(NSString *)layout
            variant:(NSString *)variant
            options:(NSString *)options
          setxkbmap:(NSString *)setxkbmapPath
              error:(NSString **)error;

/* Apple ISO keyboards have the key left of 1 and the key left of Z swapped
 * against PC ISO boards, and XKB's applealu_iso model does not remap them. */
+ (BOOL)needsAppleISOKeySwapForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
+ (BOOL)applyAppleISOKeySwap;

@end
