/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
#import <Foundation/Foundation.h>

/*
 * Checks whether a GNUstep message-port server registered under `name`
 * actually answers a Distributed Objects round trip within `timeout`
 * seconds.  If a server is registered but does not answer in time (the
 * process is alive - its listening socket accepts a connection - but its
 * run loop is not turning, e.g. blocked in a library call outside any
 * run loop source), every process named `killIfStuckComm` owned by the
 * calling user is killed, so a fresh, responsive server can register in
 * its place the next time something needs it.
 *
 * Returns YES if nothing needed fixing (no server registered, or the
 * registered one answered in time); NO if an unresponsive server was
 * found and killed.
 */
BOOL GWEnsureResponsivePasteboardServer(NSString *name,
  const char *killIfStuckComm, NSTimeInterval timeout);
