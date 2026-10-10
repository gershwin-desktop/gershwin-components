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
    (void)connected;   /* connection state does not license discarding the cache */
    if ([scanResult count] > 0) {
        return scanResult;
    }
    return cachedList ?: @[];
}

@end
