/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Wakes the device monitor the moment a disk is attached, removed or its
// media changes, so the list does not wait for the next poll. Only channels
// an unprivileged process may read are used: kernel uevents on Linux, the
// devd socket on FreeBSD.
@interface DUDeviceEventSource : NSObject

// nil when this platform offers no such channel; the monitor then polls.
+ (instancetype)sourceForPlatform;

// The handler runs on the source's own thread after the burst of events
// that one plug produces has been quiet for a short moment.
- (BOOL)startWithHandler:(void (^)(void))handler;

- (void)stop;

@end
