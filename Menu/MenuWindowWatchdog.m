/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MenuWindowWatchdog.h"

static const NSUInteger kUnmappedTicksBeforeClear = 2;

void MenuWatchdogReset(MenuWatchdogState *state)
{
    state->windowId = 0;
    state->unmappedTicks = 0;
}

BOOL MenuWatchdogShouldClear(MenuWatchdogState *state,
                             unsigned long windowId,
                             BOOL valid,
                             BOOL mapped)
{
    if (state->windowId != windowId) {
        MenuWatchdogReset(state);
        state->windowId = windowId;
    }
    if (!valid) {
        return YES;
    }
    if (mapped) {
        state->unmappedTicks = 0;
        return NO;
    }
    state->unmappedTicks++;
    return state->unmappedTicks >= kUnmappedTicksBeforeClear;
}
