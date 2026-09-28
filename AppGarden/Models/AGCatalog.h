/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGApp;

// The parsed feed: every item in display order (the canonical order; the
// Discover page shuffles it, see AGDiscoverOrder), the categories it uses,
// and when the document was fetched (the cache banner shows that date).
@interface AGCatalog : NSObject

@property (nonatomic, copy, readonly) NSArray<AGApp *> *apps;         // sorted by displayName
@property (nonatomic, copy, readonly) NSArray<NSString *> *categories; // distinct, sidebar order
@property (nonatomic, strong, readonly) NSDate *fetchDate;

// A nil fetchDate means "now", so a caller that has no date still gets one
// to show instead of an empty banner.
- (instancetype)initWithApps:(NSArray<AGApp *> *)apps fetchDate:(NSDate *)fetchDate;

- (AGApp *)appNamed:(NSString *)name;

// Either spelling of a category works: the raw name the feed uses ("Game")
// or the name the sidebar shows ("Games"). A nil category returns nothing.
- (NSArray<AGApp *> *)appsInCategory:(NSString *)category;

@end
