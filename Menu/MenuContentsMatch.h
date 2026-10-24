/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* YES when the two menus look the same to the user: the same items with the
   same titles, enabled states, check marks and submenus, at every level.
   Tags and represented objects are not compared: an app that renumbers its
   menu without changing anything visible needs no menu bar rebuild. */
BOOL MenuContentsMatch(NSMenu *a, NSMenu *b);
