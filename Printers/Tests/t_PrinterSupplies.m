/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* What the Supplies tab of the printer options shows, made from the IPP
 * marker-* attributes a printer reports: ink and toner with a level and a
 * color, no waste containers, no invented levels.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "PrinterSupplies.h"

static PrinterSupply *At(NSArray *a, NSUInteger i)
{
    return [a objectAtIndex:i];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("levels and colors are taken over")
    {
        NSArray *s = [PrinterSupply suppliesFromMarkerNames:@[@"Black", @"Cyan"]
                                                     levels:@[@80, @20]
                                                     colors:@[@"#000000", @"#00ffff"]
                                                      types:@[@"toner", @"toner"]];
        PASS([s count] == 2, "two supplies");
        PASS_EQUAL([At(s, 0) name], @"Black", "name kept");
        PASS([At(s, 0) level] == 80, "level kept");
        PASS_EQUAL([At(s, 1) colorHex], @"#00FFFF", "color upper-cased");
    }
    END_SET("levels and colors are taken over")

    START_SET("levels a printer cannot say are unknown, not zero")
    {
        NSArray *s = [PrinterSupply suppliesFromMarkerNames:@[@"A", @"B", @"C", @"D"]
                                                     levels:@[@-1, @-2, @-3, @150]
                                                     colors:nil types:nil];
        PASS([At(s, 0) level] == PrinterSupplyLevelUnknown, "-1 is unknown");
        PASS([At(s, 1) level] == PrinterSupplyLevelUnknown, "-2 is unknown");
        PASS([At(s, 2) level] == PrinterSupplyLevelUnknown, "-3 (some left) is unknown");
        PASS([At(s, 3) level] == 100, "more than 100 is clamped");
    }
    END_SET("levels a printer cannot say are unknown, not zero")

    START_SET("colors that are not a color are dropped")
    {
        NSArray *s = [PrinterSupply suppliesFromMarkerNames:@[@"A", @"B", @"C"]
                                                     levels:@[@10, @10, @10]
                                                     colors:@[@"none", @"#12", @"red"]
                                                      types:nil];
        PASS([At(s, 0) colorHex] == nil, "none");
        PASS([At(s, 1) colorHex] == nil, "too short");
        PASS([At(s, 2) colorHex] == nil, "not hex");
    }
    END_SET("colors that are not a color are dropped")

    START_SET("waste containers are not supplies")
    {
        NSArray *s = [PrinterSupply suppliesFromMarkerNames:@[@"Black", @"Waste Toner"]
                                                     levels:@[@50, @10]
                                                     colors:nil
                                                      types:@[@"toner", @"waste-toner"]];
        PASS([s count] == 1, "only the toner");
        PASS_EQUAL([At(s, 0) name], @"Black", "the right one");
    }
    END_SET("waste containers are not supplies")

    START_SET("short or missing attribute lists never crash or invent")
    {
        NSArray *s = [PrinterSupply suppliesFromMarkerNames:@[@"A", @"B"]
                                                     levels:@[@40]
                                                     colors:nil types:nil];
        PASS([s count] == 2, "the names decide how many");
        PASS([At(s, 1) level] == PrinterSupplyLevelUnknown, "missing level is unknown");
        PASS([[PrinterSupply suppliesFromMarkerNames:nil levels:nil colors:nil types:nil] count] == 0,
             "nothing reported, nothing shown");
    }
    END_SET("short or missing attribute lists never crash or invent")

    [arp release];
    return 0;
}
