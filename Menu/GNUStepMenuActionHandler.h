/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface GNUStepMenuActionHandler : NSObject
+ (void)performMenuAction:(id)sender;

// Returns a connection to an already looked-up client that the CALLING thread
// can use, WITHOUT performing a DO name lookup, or nil.
// Safe to call on the main thread even if the client is stalled.
+ (NSConnection *)existingConnectionForClient:(NSString *)clientName;

// Records the client port of a connection made by any thread (typically a
// background probe) so later main-thread lookups never block on the name
// server.
+ (void)cacheConnection:(NSConnection *)connection forClient:(NSString *)clientName;
@end
