/* t_WorldClockList.m - ObjectTesting coverage for the Clock extra's Global
 * submenu builder: one representative city per distinct UTC offset, plus
 * the user's own zone, sorted relative to the user. Headless, uses a fixed
 * date so results do not depend on when the test runs.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "WorldClockList.h"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* 2026-06-15 12:00 UTC - well into northern-hemisphere daylight time,
       so European/US zones exercise their DST offsets, not just standard
       time. */
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:1781179200];

    /* --- user's own zone is present and marked --- */
    {
        NSTimeZone *berlin = [NSTimeZone timeZoneWithName:@"Europe/Berlin"];
        NSArray<WorldClockEntry *> *entries =
            [WorldClockList worldClockEntriesForDate:date userTimeZone:berlin];

        NSInteger berlinOffset = [berlin secondsFromGMTForDate:date];
        WorldClockEntry *userEntry = nil;
        for (WorldClockEntry *e in entries) {
            if ([e isUserZone]) { userEntry = e; break; }
        }
        PASS(userEntry != nil, "the user's own zone appears in the list");
        PASS(userEntry != nil && [userEntry offsetSeconds] == berlinOffset,
             "the user's entry carries the user's own UTC offset (summer, +2h)");
        PASS_EQUAL([userEntry timeZoneName], @"Europe/Berlin",
                   "the user's entry names the user's own IANA zone, not a stand-in city");

        NSUInteger userCount = 0;
        for (WorldClockEntry *e in entries) {
            if ([e isUserZone]) userCount++;
        }
        PASS(userCount == 1, "the user's zone is marked exactly once, not duplicated alongside a same-offset city");
    }

    /* --- one representative per distinct offset (scannability) --- */
    {
        NSTimeZone *utc = [NSTimeZone timeZoneWithName:@"UTC"];
        NSArray<WorldClockEntry *> *entries =
            [WorldClockList worldClockEntriesForDate:date userTimeZone:utc];

        NSMutableSet<NSNumber *> *seenOffsets = [NSMutableSet set];
        BOOL sawDuplicateOffset = NO;
        for (WorldClockEntry *e in entries) {
            NSNumber *key = @([e offsetSeconds]);
            if ([seenOffsets containsObject:key]) sawDuplicateOffset = YES;
            [seenOffsets addObject:key];
        }
        PASS(!sawDuplicateOffset, "no two entries share the same UTC offset");
        PASS([entries count] > 10, "the curated city list yields a real spread of offsets, not a token few");
    }

    /* --- sorted by offset relative to the user, not raw UTC --- */
    {
        NSTimeZone *tokyo = [NSTimeZone timeZoneWithName:@"Asia/Tokyo"];
        NSArray<WorldClockEntry *> *entries =
            [WorldClockList worldClockEntriesForDate:date userTimeZone:tokyo];

        NSInteger tokyoOffset = [tokyo secondsFromGMTForDate:date];
        NSInteger previousDelta = NSIntegerMin;
        BOOL monotonic = YES;
        for (WorldClockEntry *e in entries) {
            NSInteger delta = [e offsetSeconds] - tokyoOffset;
            if (delta < previousDelta) monotonic = NO;
            previousDelta = delta;
        }
        PASS(monotonic, "entries are sorted by offset delta from the user's zone, ascending");

        WorldClockEntry *first = [entries firstObject];
        PASS(first != nil && [first offsetSeconds] <= tokyoOffset,
             "the list starts with a zone behind (or equal to) the user, not an arbitrary one");
    }

    [arp release];
    return 0;
}
