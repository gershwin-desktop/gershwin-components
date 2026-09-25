/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WorldClockList.h"

@implementation WorldClockEntry

- (instancetype)initWithCityName:(NSString *)cityName
                     timeZoneName:(NSString *)timeZoneName
                     abbreviation:(NSString *)abbreviation
                    offsetSeconds:(NSInteger)offsetSeconds
                       isUserZone:(BOOL)isUserZone
{
    self = [super init];
    if (self) {
        _cityName = [cityName copy];
        _timeZoneName = [timeZoneName copy];
        _abbreviation = [abbreviation copy];
        _offsetSeconds = offsetSeconds;
        _isUserZone = isUserZone;
    }
    return self;
}

@end

/* One city per distinct standard UTC offset, roughly spanning UTC-10 to
 * UTC+13 so nearly every offset band has a representative. Listed west to
 * east; the exact ordering here does not matter since the result is
 * re-sorted relative to the user's own offset, but keeping it geographic
 * makes this table easy to audit by eye. */
static NSArray<NSArray<NSString *> *> *WorldClockCandidateCities(void)
{
    return @[
        @[@"Honolulu",    @"Pacific/Honolulu"],
        @[@"Anchorage",   @"America/Anchorage"],
        @[@"Los Angeles", @"America/Los_Angeles"],
        @[@"Denver",      @"America/Denver"],
        @[@"Chicago",     @"America/Chicago"],
        @[@"New York",    @"America/New_York"],
        @[@"Halifax",     @"America/Halifax"],
        @[@"Sao Paulo",   @"America/Sao_Paulo"],
        @[@"Reykjavik",   @"Atlantic/Reykjavik"],
        @[@"London",      @"Europe/London"],
        @[@"Berlin",      @"Europe/Berlin"],
        @[@"Cairo",       @"Africa/Cairo"],
        @[@"Moscow",      @"Europe/Moscow"],
        @[@"Dubai",       @"Asia/Dubai"],
        @[@"Karachi",     @"Asia/Karachi"],
        @[@"Kolkata",     @"Asia/Kolkata"],
        @[@"Dhaka",       @"Asia/Dhaka"],
        @[@"Bangkok",     @"Asia/Bangkok"],
        @[@"Shanghai",    @"Asia/Shanghai"],
        @[@"Tokyo",       @"Asia/Tokyo"],
        @[@"Sydney",      @"Australia/Sydney"],
        @[@"Noumea",      @"Pacific/Noumea"],
        @[@"Auckland",    @"Pacific/Auckland"],
    ];
}

/* "Europe/Berlin" -> "Berlin", "America/Argentina/Buenos_Aires" ->
 * "Buenos Aires" - a readable fallback name for whatever zone the user
 * happens to be in, when it is not one of the curated cities above. */
static NSString *CityNameFromTimeZoneName(NSString *timeZoneName)
{
    NSString *last = [[timeZoneName componentsSeparatedByString:@"/"] lastObject];
    return [last stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

@implementation WorldClockList

+ (NSArray<WorldClockEntry *> *)worldClockEntriesForDate:(NSDate *)date
                                             userTimeZone:(NSTimeZone *)userTimeZone
{
    /* TODO: dedup by offset, add the user's own zone, sort relative to it. */
    (void)date;
    (void)userTimeZone;
    return @[];
}

@end
