/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Which of the destinations CUPS reports are shown as rows.  One physical
 * printer is one row: CUPS makes an implicit class "<queue>@<host>" around a
 * printer it discovered on the network, and a class whose only member is a
 * destination listed itself is that same printer a second time; so is the
 * "<queue>@<host>" queue cups-browsed makes for a printer whose queue is
 * listed. */
@interface PrinterListing : NSObject

/* entries are dictionaries with the destination's "name", its "deviceURI" and,
 * for a class, its member names under "members".  The names to show, in the
 * order given. */
+ (NSArray *)visibleNamesFromEntries:(NSArray *)entries;

@end
