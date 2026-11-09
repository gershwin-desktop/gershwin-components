/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WApplication.h"

@implementation WApplication

- (id)init
{
    if ((self = [super init])) {
        repeatFilter = [[WKeyRepeatFilter alloc] init];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(keyboardFocusLeft:)
                   name:NSApplicationDidResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(keyboardFocusLeft:)
                   name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [repeatFilter release];
    [super dealloc];
}

- (void)sendEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    if (type == NSKeyDown) {
        currentKeyDownRepeats = [repeatFilter noteKeyDown:[event keyCode]
                                                       at:[event timestamp]];
        [super sendEvent:event];
        currentKeyDownRepeats = NO;
        return;
    }
    if (type == NSKeyUp)
        [repeatFilter noteKeyUp:[event keyCode] at:[event timestamp]];
    [super sendEvent:event];
}

/* Key-ups of keys still held when the keyboard moves elsewhere go to that
   window or app; a press after coming back must count as a press. */
- (void)keyboardFocusLeft:(NSNotification *)note
{
    [repeatFilter reset];
}

- (BOOL)currentKeyDownRepeats
{
    return currentKeyDownRepeats;
}

@end
