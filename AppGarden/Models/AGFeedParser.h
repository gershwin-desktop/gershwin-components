/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGCatalog;

// Turns the feed document into a catalog. A document that is not a usable
// feed fails with an error the user can read; a single malformed item only
// costs that item.
@interface AGFeedParser : NSObject

// date is when the bytes were fetched; nil means now.
+ (AGCatalog *)catalogFromData:(NSData *)data fetchDate:(NSDate *)date error:(NSError **)error;

@end
