/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "NetworkBackend.h"

/* Decides what network list the WLAN menu should keep after a scan, pure
 * logic extracted so it can be tested without a real backend or hardware.
 *
 * The bug this exists to pin: several WLAN drivers suppress full off-channel
 * scanning while the radio is associated to an AP, to avoid disrupting the
 * live link. A scan requested while connected then often comes back empty
 * even though the neighbourhood has not changed. The old code let "we are
 * connected" excuse replacing the cached list with that empty result, which
 * is backwards - being connected is a reason to trust the cache MORE, not
 * less. Only a scan that actually found something should replace it. */
@interface WLANMenuListPolicy : NSObject

+ (NSArray<WLAN *> *)networkListAfterScan:(NSArray<WLAN *> *)scanResult
                                cachedList:(NSArray<WLAN *> *)cachedList
                                 connected:(BOOL)connected;

@end
