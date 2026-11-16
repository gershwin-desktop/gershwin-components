/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Calls a block on the current run loop whenever a descriptor becomes
 * readable.  The descriptor is the run loop's input source, so a thread
 * that only waits for it sleeps in poll() instead of spinning. */
@interface NMDDescriptorWatcher : NSObject

- (instancetype) initWithDescriptor: (int)fd handler: (void (^)(void))handler;

/* Stops watching; must be called before the descriptor is closed. */
- (void) invalidate;

@end
