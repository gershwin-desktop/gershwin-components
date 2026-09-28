/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* The order the Discover page lists the catalog in.
 *
 * Discover is the one page without a scope: it shows everything the feed
 * offers, and in the catalog's own order that reads as the alphabet, which
 * buries most of the catalog under the A's. So Discover is shuffled.
 *
 * Only Discover is. A category page and the Downloaded list are lists of
 * things the user went looking for, and those keep the catalog's
 * alphabetical order, which is a fact about the apps rather than an
 * arbitrary arrangement of them.
 *
 * Foundation only, so the permutation can be pinned down without a window;
 * see Tests/Unit/t_AGDiscoverOrder.m.
 */
@interface AGDiscoverOrder : NSObject

/* A copy of apps in random order: the same elements, each exactly once,
   and never nil. Untyped so a test can shuffle anything, not just apps.

   Callers shuffle once and then hold the result. A page that reorders
   itself every time it is repopulated moves the cards under the user,
   throws away the scroll offset and drops the focused card. */
+ (NSArray *)shuffled:(NSArray *)apps;

@end
