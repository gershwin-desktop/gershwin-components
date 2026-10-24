/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "GMLocalSession.h"

/* The two UDP sockets of one local session: the control port and the data
 * port right above it.  IPv4 only for now: that is what every peer seen so
 * far announces, and it works on kernels built without IPv6. */
@interface GMUDPEndpoint : NSObject <GMSessionTransport>

/* Binds both ports or fails, with errno in the error. */
- (instancetype) initWithPort: (uint16_t)controlPort
                      handler: (void (^)(NSData *data, NSData *from, BOOL control))handler
                        error: (NSError **)error;

@property (nonatomic, readonly) uint16_t port;

- (void) close;

@end
