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
    NSInteger userOffset = [userTimeZone secondsFromGMTForDate:date];
    NSString *userCityName = CityNameFromTimeZoneName([userTimeZone name]);

    /* Keyed by offset so only one representative survives per distinct
     * UTC offset, per the menu's scannability requirement. */
    NSMutableDictionary<NSNumber *, WorldClockEntry *> *byOffset = [NSMutableDictionary dictionary];

    for (NSArray<NSString *> *candidate in WorldClockCandidateCities()) {
        NSString *cityName = candidate[0];
        NSString *tzName = candidate[1];
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzName];
        if (!tz) continue;

        NSInteger offset = [tz secondsFromGMTForDate:date];
        NSNumber *key = @(offset);
        if (byOffset[key] != nil) continue;   /* first candidate at this offset wins */

        NSString *abbreviation = [tz abbreviationForDate:date] ?: @"";
        BOOL isUserZone = (offset == userOffset);
        WorldClockEntry *entry = [[WorldClockEntry alloc] initWithCityName:cityName
                                                                timeZoneName:tzName
                                                                abbreviation:abbreviation
                                                               offsetSeconds:offset
                                                                  isUserZone:isUserZone];
        byOffset[key] = entry;
    }

    /* The user's own zone always appears, under its own name - replacing a
     * curated city that happens to share its offset rather than sitting
     * alongside it as a confusing duplicate. */
    {
        NSString *userAbbreviation = [userTimeZone abbreviationForDate:date] ?: @"";
        WorldClockEntry *userEntry = [[WorldClockEntry alloc] initWithCityName:userCityName
                                                                    timeZoneName:[userTimeZone name]
                                                                    abbreviation:userAbbreviation
                                                                   offsetSeconds:userOffset
                                                                      isUserZone:YES];
        byOffset[@(userOffset)] = userEntry;
    }

    NSArray<WorldClockEntry *> *entries = [byOffset allValues];
    return [entries sortedArrayUsingComparator:^NSComparisonResult(WorldClockEntry *a, WorldClockEntry *b) {
        NSInteger da = a.offsetSeconds - userOffset;
        NSInteger db = b.offsetSeconds - userOffset;
        if (da < db) return NSOrderedAscending;
        if (da > db) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

@end
