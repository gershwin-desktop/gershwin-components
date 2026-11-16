/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <PreferencePanes/PreferencePanes.h>

@class MIDIPaneController;

/* The MIDI preference pane: network MIDI sessions, the hosts they can
   connect to, connected peers and the routing to local MIDI ports. */
@interface MIDIPane : NSPreferencePane
@end
