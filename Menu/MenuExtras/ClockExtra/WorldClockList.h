/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* One row of the Clock extra's Global submenu. */
@interface WorldClockEntry : NSObject

@property (nonatomic, copy, readonly) NSString *cityName;
@property (nonatomic, copy, readonly) NSString *timeZoneName;
@property (nonatomic, copy, readonly) NSString *abbreviation;
@property (nonatomic, readonly) NSInteger offsetSeconds;
@property (nonatomic, readonly) BOOL isUserZone;

- (instancetype)initWithCityName:(NSString *)cityName
                     timeZoneName:(NSString *)timeZoneName
                     abbreviation:(NSString *)abbreviation
                    offsetSeconds:(NSInteger)offsetSeconds
                       isUserZone:(BOOL)isUserZone;

@end

/* Builds the Global submenu's row list: one representative city per distinct
 * UTC offset (a curated set of major cities, so the same "CST" abbreviation
 * used by both a US and a Chinese zone at different offsets never collides),
 * plus the user's own zone, sorted by how far each offset is from the
 * user's own - reads as one scannable "earlier ... me ... later" line
 * rather than an alphabetical jumble of abbreviations. Pure function of
 * `date` and `userTimeZone`: no wall-clock reads, so it is safe to unit
 * test with a fixed date. */
@interface WorldClockList : NSObject

+ (NSArray<WorldClockEntry *> *)worldClockEntriesForDate:(NSDate *)date
                                             userTimeZone:(NSTimeZone *)userTimeZone;

@end
