/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

// How many watchdog ticks in a row the shown window has been found unmapped.
typedef struct {
    unsigned long windowId;
    NSUInteger unmappedTicks;
} MenuWatchdogState;

// Forgets the count, e.g. when the watchdog stops looking at the window.
void MenuWatchdogReset(MenuWatchdogState *state);

// Decides one watchdog tick for the shown window. A destroyed window is
// cleared at once; an unmapped one only when it was unmapped on the previous
// tick too, because some apps report windows unmapped while creating them.
BOOL MenuWatchdogShouldClear(MenuWatchdogState *state,
                             unsigned long windowId,
                             BOOL valid,
                             BOOL mapped);
