/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Maps the raw freedesktop category names of the feed to what the sidebar
// and the detail page show, and fixes their order. The feed mixes purposes
// (Utility, Game) with toolkits (Qt, GTK); the toolkits are hidden because
// they say nothing about what an application is for.
@interface AGCategoryNames : NSObject

// Nil for a nil category, the raw name for anything not in the table, and
// the localized display name otherwise.
+ (NSString *)displayNameForCategory:(NSString *)category;

// YES for the toolkit and desktop categories that stay out of the sidebar.
// A nil or unknown category is not hidden.
+ (BOOL)isHiddenCategory:(NSString *)category;

// Sidebar position: known categories come first in this order, unknown ones
// get NSIntegerMax and sort alphabetically after them.
+ (NSInteger)sortOrderForCategory:(NSString *)category;

// Sorts raw category names the way the sidebar lists them.
+ (NSArray<NSString *> *)sortedRawCategories:(NSArray<NSString *> *)categories;

@end
