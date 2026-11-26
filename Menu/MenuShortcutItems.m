/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuShortcutItems.h"

static void MenuShortcutItemsCollect(NSArray *items, id handler, NSMutableArray *found)
{
    /* A snapshot: [NSMenu itemArray] is the menu's live array in GNUstep,
       and the menu can change while it is walked (the system menu is still
       being filled, for one), which would abort the walk midway. */
    NSArray *snapshot = [items copy];
    for (NSMenuItem *item in snapshot) {
        if ([item target] == handler && [[item keyEquivalent] length] > 0) {
            [found addObject:item];
        }
        if ([item hasSubmenu]) {
            MenuShortcutItemsCollect([[item submenu] itemArray], handler, found);
        }
    }
}

NSArray *MenuItemsWithShortcutsHandledBy(NSArray *items, id handler)
{
    NSMutableArray *found = [NSMutableArray array];
    MenuShortcutItemsCollect(items, handler, found);
    return found;
}
