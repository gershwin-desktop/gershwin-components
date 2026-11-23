/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* The level of a supply the printer does not report as a number. */
extern const NSInteger PrinterSupplyLevelUnknown;

/* One ink or toner supply as the printer reports it in the IPP marker-*
 * attributes. */
@interface PrinterSupply : NSObject
{
    NSString *name;
    NSInteger level;
    NSString *colorHex;
}

@property (readonly, copy) NSString *name;
/* 0 to 100, or PrinterSupplyLevelUnknown. */
@property (readonly) NSInteger level;
/* "#RRGGBB", or nil when the printer gives none. */
@property (readonly, copy) NSString *colorHex;

/* The supplies to show, in the printer's order.  The names decide how many
 * there are; the other lists may be shorter or nil.  Waste containers are left
 * out.  A level the printer cannot state (below 0) is unknown, never zero. */
+ (NSArray *)suppliesFromMarkerNames:(NSArray *)names
                              levels:(NSArray *)levels
                              colors:(NSArray *)colors
                               types:(NSArray *)types;

@end
