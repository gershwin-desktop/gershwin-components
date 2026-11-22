/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCWSDScanEvent;

/*
 * Receives the printer's "someone pressed Start for you" notifications: a
 * small HTTP endpoint on a thread of Scanner itself, so nothing runs once
 * Scanner quits. Only the printer's own address is listened to; anything
 * else on the network is turned away.
 */
@interface SCWSDEventListener : NSObject

/* The handler runs on the main thread */
- (instancetype) initWithPrinterHost: (NSString *)host
                             handler: (void (^)(SCWSDScanEvent *event))handler;

/* NO when no port could be opened */
- (BOOL) start;
- (void) stop;

/* Where the printer should send its notifications, as it can reach this computer */
- (NSString *) notifyURL;

@end
