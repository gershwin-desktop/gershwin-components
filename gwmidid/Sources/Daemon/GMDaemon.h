/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "GMDaemonControl.h"

/* Ties the pieces together for one user: the configured sessions with
 * their sockets and MIDI ports, the mDNS directory, the timers, and the
 * control interface. */
@interface GMDaemon : NSObject <GMDaemonControl>

/* Fails when another gwmidid of this user runs or there is no MIDI port
 * layer; individual sessions that cannot start are reported in -status. */
- (BOOL) startWithError: (NSString **)error;

/* Ends every session with BY and withdraws the announcements. */
- (void) shutdown;

@end
