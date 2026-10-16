/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WKEY_REPEAT_FILTER_H
#define WKEY_REPEAT_FILTER_H

#import <Foundation/Foundation.h>

/* Tells a held key's auto-repeat apart from a new press.  X sends each
   repeat as a key-up plus a key-down with the same time; the X11 backend
   reports the key-down with isARepeat NO and drops the key-up only when it
   already sees the key-down queued behind it.  So a key-down is a repeat
   when its key was not released since its last key-down, or when it has
   the time of that key's last key-up. */
@interface WKeyRepeatFilter : NSObject
{
    NSMutableIndexSet *held;
    NSMutableDictionary *lastUp;   // key code -> time of its last key-up
}

/// Returns YES when this key-down is a repeat of a key still held.
- (BOOL)noteKeyDown:(unsigned short)keyCode at:(NSTimeInterval)time;
- (void)noteKeyUp:(unsigned short)keyCode at:(NSTimeInterval)time;
/// Forget every held key, e.g. when the key-ups may go to another app.
- (void)reset;

@end

#endif
