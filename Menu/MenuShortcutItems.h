/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* The items of a menu tree, submenus included, that an importer's action
   handler set up itself (their target is handler) and that have a key
   equivalent: the ones whose shortcuts the importer registers again when an
   application's cached menu is shown.  Everything else in the tree - above
   all Menu's own system menu, which sits in every application's menu - keeps
   its target, action and shortcut. */
NSArray *MenuItemsWithShortcutsHandledBy(NSArray *items, id handler);
