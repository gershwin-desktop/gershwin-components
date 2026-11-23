/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* The groups whose members CUPS lets manage printers: the SystemGroup of the
 * system's own cups-files.conf.  Which group that is depends on the system
 * (lpadmin on Debian, sys on Arch, wheel on the BSDs), so it is read, not
 * guessed. */
@interface CupsSystemGroups : NSObject

/* The groups on the SystemGroup lines of a cups-files.conf, in order, without
 * duplicates and without root (nobody joins that).  Empty when there are
 * none. */
+ (NSArray *)systemGroupsInConfiguration:(NSString *)configuration;

/* The same for the cups-files.conf this system has, nil when it has none
 * (CUPS is not installed). */
+ (NSArray *)systemGroups;

@end
