/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PrinterListing.h"

@implementation PrinterListing

/* cups-browsed makes a queue "<base>@<host>" that forwards to a discovered
   printer through an implicitclass:// device.  When the base queue is listed
   too, it is the printer a second time. */
+ (BOOL)isStandInForListedPrinter:(NSDictionary *)entry among:(NSSet *)listed
{
    NSString *uri = [entry objectForKey:@"deviceURI"];
    NSString *name = [entry objectForKey:@"name"];
    NSRange at = [name rangeOfString:@"@"];
    if (![uri hasPrefix:@"implicitclass://"] || at.location == NSNotFound || at.location == 0) {
        return NO;
    }
    return [listed containsObject:[name substringToIndex:at.location]];
}

+ (NSArray *)visibleNamesFromEntries:(NSArray *)entries
{
    NSMutableSet *listed = [NSMutableSet set];
    for (NSDictionary *entry in entries) {
        [listed addObject:[entry objectForKey:@"name"]];
    }
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSArray *members = [entry objectForKey:@"members"];
        BOOL sameAsItsMember = [members count] == 1 && [listed containsObject:[members objectAtIndex:0]];
        if (!sameAsItsMember && ![self isStandInForListedPrinter:entry among:listed]) {
            [visible addObject:[entry objectForKey:@"name"]];
        }
    }
    return visible;
}

@end
