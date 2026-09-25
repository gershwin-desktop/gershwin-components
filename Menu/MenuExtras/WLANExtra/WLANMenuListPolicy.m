/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANMenuListPolicy.h"

@implementation WLANMenuListPolicy

+ (NSArray<WLAN *> *)networkListAfterScan:(NSArray<WLAN *> *)scanResult
                                cachedList:(NSArray<WLAN *> *)cachedList
                                 connected:(BOOL)connected
{
    /* TODO: never let an empty scan wipe out the cached list. */
    (void)cachedList;
    (void)connected;
    return scanResult ?: @[];
}

@end
