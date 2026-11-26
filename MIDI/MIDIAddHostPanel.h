/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>
#import "MIDINetworkModels.h"

/* Asks for a host that discovery cannot find (another subnet, a VPN):
   name, address and port. */
@interface MIDIAddHostPanel : NSObject

/* Runs modally; nil when cancelled. The host is not validated here: the
   backend's rules apply, and its error appears in the status line. */
- (MIDINetworkHost *)runModal;

@end
