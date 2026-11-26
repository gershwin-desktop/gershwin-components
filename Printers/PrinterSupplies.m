/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PrinterSupplies.h"

const NSInteger PrinterSupplyLevelUnknown = -1;

@implementation PrinterSupply

@synthesize name, level, colorHex;

- (id)initWithName:(NSString *)aName level:(NSInteger)aLevel colorHex:(NSString *)aColor
{
    self = [super init];
    if (self) {
        name = [aName copy];
        level = aLevel;
        colorHex = [aColor copy];
    }
    return self;
}

- (void)dealloc
{
    [name release];
    [colorHex release];
    [super dealloc];
}

static NSString *ColorFromAttribute(id value)
{
    if (![value isKindOfClass:[NSString class]] || [value length] != 7
        || [value characterAtIndex:0] != '#') {
        return nil;
    }
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:
                               @"0123456789abcdefABCDEF"] invertedSet];
    if ([[value substringFromIndex:1] rangeOfCharacterFromSet:notHex].location != NSNotFound) {
        return nil;
    }
    return [value uppercaseString];
}

+ (NSArray *)suppliesFromMarkerNames:(NSArray *)names
                              levels:(NSArray *)levels
                              colors:(NSArray *)colors
                               types:(NSArray *)types
{
    NSMutableArray *supplies = [NSMutableArray array];
    for (NSUInteger i = 0; i < [names count]; i++) {
        id type = i < [types count] ? [types objectAtIndex:i] : nil;
        if ([type isKindOfClass:[NSString class]]
            && [type rangeOfString:@"waste"].location != NSNotFound) {
            continue;
        }
        NSInteger level = PrinterSupplyLevelUnknown;
        if (i < [levels count] && [[levels objectAtIndex:i] isKindOfClass:[NSNumber class]]) {
            NSInteger reported = [[levels objectAtIndex:i] integerValue];
            level = reported < 0 ? PrinterSupplyLevelUnknown : MIN(reported, 100);
        }
        NSString *color = i < [colors count] ? ColorFromAttribute([colors objectAtIndex:i]) : nil;
        PrinterSupply *supply = [[PrinterSupply alloc] initWithName:[names objectAtIndex:i]
                                                              level:level
                                                           colorHex:color];
        [supplies addObject:supply];
        [supply release];
    }
    return supplies;
}

@end
