/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGCatalog;
@class AGApp;

// Answers "what matches what the user just typed", scoped to one category.
// Deliberately a linear scan: the whole catalog is a few thousand short
// strings, which costs less than keeping a second index in sync every time
// the feed is refreshed.
@interface AGSearchIndex : NSObject

- (instancetype)initWithCatalog:(AGCatalog *)catalog;

// The category is either the raw feed name ("Game") or the display name the
// sidebar shows ("Games"); nil searches the whole catalog. An empty query
// returns that scope in catalog order.
- (NSArray<AGApp *> *)appsMatchingQuery:(NSString *)query inCategory:(NSString *)categoryOrNil;

@end
