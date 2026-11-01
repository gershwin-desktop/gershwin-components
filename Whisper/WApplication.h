/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WAPPLICATION_H
#define WAPPLICATION_H

#import <AppKit/AppKit.h>
#import "WKeyRepeatFilter.h"

/* Sees every key event before the menu's key equivalents and the focused
   button do, so an action can ask whether the key-down that triggered it
   is only the auto-repeat of a held key. */
@interface WApplication : NSApplication
{
    WKeyRepeatFilter *repeatFilter;
    BOOL currentKeyDownRepeats;
}

/// YES while dispatching a key-down that repeats a key still held.
- (BOOL)currentKeyDownRepeats;

@end

#endif
