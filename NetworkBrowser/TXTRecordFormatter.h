/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface TXTRecordFormatter : NSObject

/* Text for one TXT value: NSData as UTF-8 (or a byte count if it is not
 * UTF-8), nil for NSNull, which is what libs-base stores for a key that
 * has no value at all. */
+ (NSString *)stringForValue:(id)value;

/* One "  key: value" line per entry ("  key" if there is no value), sorted
 * by key. Entries with an empty key are skipped. Returns nil when no line
 * remains (nil, empty or only empty-key dictionary) so callers skip the
 * heading. */
+ (NSString *)linesForTXTDictionary:(NSDictionary *)dict;

@end
