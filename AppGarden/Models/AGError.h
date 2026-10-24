/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A catalog document is either usable or it is an error the user reads in an
// alert. There is no third outcome, so every failure the parser reports lives
// in this one domain with one of the four codes below.
extern NSString * const AGErrorDomain;

typedef NS_ENUM(NSInteger, AGErrorCode) {
  // The bytes are not JSON at all (truncated download, HTML error page).
  AGErrorNotJSON = 1,
  // JSON, but not the object-with-items shape the feed promises.
  AGErrorTopLevelNotDictionary,
  // The document has no `items` key.
  AGErrorItemsMissing,
  // `items` is present but is not an array.
  AGErrorItemsNotArray,
};
