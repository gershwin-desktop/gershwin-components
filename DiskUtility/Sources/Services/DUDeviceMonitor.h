/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUStorageManager;

// Keeps the topology current: a kernel event source (see
// DUDeviceEventSource) refreshes within a fraction of a second of a plug or
// pull, and a timer polls as a safety net, or as the only mechanism where no
// unprivileged event channel exists. Each refresh runs on a background
// thread so the run loop never blocks.
@interface DUDeviceMonitor : NSObject

@property (nonatomic, strong, readonly) DUStorageManager *storageManager;
@property (nonatomic, readonly) NSTimeInterval interval;

- (instancetype)initWithStorageManager:(DUStorageManager *)storageManager
    NS_DESIGNATED_INITIALIZER;

// Starts polling. The timer lives on the calling thread's run loop, so call
// -start from a thread that runs one (the main thread in practice).
- (void)start;

- (void)stop;

@end
