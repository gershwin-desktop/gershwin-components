/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuContentsMatch.h"

BOOL MenuContentsMatch(NSMenu *a, NSMenu *b)
{
    if (a == nil || b == nil) {
        return NO;
    }
    NSArray *itemsA = [a itemArray];
    NSArray *itemsB = [b itemArray];
    if ([itemsA count] != [itemsB count]) {
        return NO;
    }
    for (NSUInteger i = 0; i < [itemsA count]; i++) {
        NSMenuItem *x = [itemsA objectAtIndex:i];
        NSMenuItem *y = [itemsB objectAtIndex:i];
        if ([x isSeparatorItem] != [y isSeparatorItem]
            || ![[x title] isEqualToString:[y title]]
            || [x isEnabled] != [y isEnabled]
            || [x state] != [y state]
            || ([x submenu] == nil) != ([y submenu] == nil)) {
            return NO;
        }
        if ([x submenu] != nil && !MenuContentsMatch([x submenu], [y submenu])) {
            return NO;
        }
    }
    return YES;
}
