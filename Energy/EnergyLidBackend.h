/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "EnergyLidCloseOnce.h"

/* Builds the "stay awake at lid close" armer for the platform this binary
 * is running on. Building it never blocks and never does privileged work -
 * that only happens once something actually arms it - but it does refuse to
 * hand out an armer at all where this platform has no known way to both
 * detect the lid and hold a lock across the close: the caller must show the
 * feature as unavailable rather than let it silently do nothing when used. */
@interface EnergyLidBackend : NSObject

/* Returns nil when unsupported, with *reason set to why (log it once - do
 * not call this again just to re-read the reason). */
+ (EnergyLidCloseOnceArmer *)createArmerWithUnsupportedReason:(NSString **)reason;

@end
