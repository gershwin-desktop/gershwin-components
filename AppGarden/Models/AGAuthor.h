/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// One entry of an item's `authors` array. Kept as its own class so the detail
// page can turn a name into a link without re-parsing feed dictionaries.
@interface AGAuthor : NSObject

@property (nonatomic, copy, readonly) NSString *name;
// Nil when the feed gave no URL or one that is not a web address, so the
// detail page renders plain text instead of a link that cannot open.
@property (nonatomic, strong, readonly) NSURL *url;

- (instancetype)initWithName:(NSString *)name url:(NSURL *)url;

// Builds an author from one feed dictionary; returns nil when the entry has
// no usable name, which is the only required key.
- (instancetype)initWithFeedAuthor:(NSDictionary *)entry;

@end
