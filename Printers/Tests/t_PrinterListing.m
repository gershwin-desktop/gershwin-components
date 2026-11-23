/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* One physical printer must be one row.  CUPS makes an implicit class named
 * "<queue>@<host>" around a printer it discovered on the network; a class
 * with a single member that is listed itself is the same printer twice.
 * Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PrinterListing.h"

static NSDictionary *Queue(NSString *name)
{
    return @{@"name": name};
}

static NSDictionary *Alias(NSString *name)
{
    return @{@"name": name,
             @"deviceURI": [NSString stringWithFormat:@"implicitclass://%@/", name]};
}

static NSDictionary *Class_(NSString *name, NSArray *members)
{
    return @{@"name": name, @"members": members};
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("a class around one listed printer is that printer again")
    {
        NSArray *entries = @[Queue(@"Samsung"), Class_(@"Samsung@host.local", @[@"Samsung"])];
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:entries], (@[@"Samsung"]),
                   "only the printer itself");
    }
    END_SET("a class around one listed printer is that printer again")

    START_SET("a browsed stand-in for a listed printer is that printer again")
    {
        NSArray *both = @[Queue(@"Samsung"), Alias(@"Samsung@host.local")];
        NSArray *alone = @[Alias(@"Other@host.local")];
        NSArray *namedLikeOne = @[Queue(@"Plain@host"), Queue(@"Plain")];
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:both], (@[@"Samsung"]),
                   "name@host with an implicitclass URI next to its base queue");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:alone], (@[@"Other@host.local"]),
                   "without the base queue it is the only way to reach the printer");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:namedLikeOne], (@[@"Plain@host", @"Plain"]),
                   "a queue only named with an @ is nothing special");
    }
    END_SET("a browsed stand-in for a listed printer is that printer again")

    START_SET("everything else stays, in the order CUPS gave")
    {
        NSArray *plain = @[Queue(@"B"), Queue(@"A")];
        NSArray *pair = @[Queue(@"P1"), Queue(@"P2"), Class_(@"Pair", @[@"P1", @"P2"])];
        NSArray *orphan = @[Class_(@"Solo", @[@"Gone"])];
        NSArray *empty = @[Class_(@"Empty", @[])];
        NSArray *none = @[];
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:plain], (@[@"B", @"A"]), "plain printers");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:pair], (@[@"P1", @"P2", @"Pair"]),
                   "a class of two printers is a class the user made");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:orphan], (@[@"Solo"]),
                   "a class whose one member is not listed has nothing to hide behind");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:empty], (@[@"Empty"]), "an empty class is shown");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:none], (@[]), "nothing");
        PASS_EQUAL([PrinterListing visibleNamesFromEntries:nil], (@[]), "nil");
    }
    END_SET("everything else stays, in the order CUPS gave")

    [arp release];
    return 0;
}
