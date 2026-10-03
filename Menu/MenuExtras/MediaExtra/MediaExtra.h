/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

#import "GSMenuExtra.h"

@interface MediaExtra : NSObject <GSMenuExtra>

/**
 * Shows what plays and steers it: a pause button while something plays, a
 * play button while it does not, and nothing at all in the menu bar when no
 * player runs that can be steered.
 *
 * What plays is whatever MPRISMediaController finds on the session bus
 * (VLC, mpv, Rhythmbox, a player in a browser) and the native Gershwin
 * player, if one runs - they are both reached through MediaHub, which is
 * also what serves the same commands to programs that ask over Distributed
 * Objects.  A player that cannot be steered by either is not shown, rather
 * than shown with nothing to steer it with.
 *
 * This extra is only built where libdbus is, because a menu bar item that
 * can do nothing is worse than no menu bar item.  The hub it asks, and the
 * Distributed Objects interface it serves, are part of Menu itself and are
 * there either way.
 */
@end
