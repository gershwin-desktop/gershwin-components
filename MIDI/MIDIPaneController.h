/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <AppKit/AppKit.h>
#import "MIDINetworkBackend.h"

/* Builds the MIDI pane in code, turns user actions into backend calls and
   renders a MIDIPaneViewState after every change. */
@interface MIDIPaneController : NSObject <MIDINetworkBackendDelegate, NSTableViewDataSource,
                                          NSTableViewDelegate, NSTextFieldDelegate>

- (NSView *)createMainView;
- (void)relayoutSubviewsForSize:(NSSize)size;
- (void)start;
- (void)stop;

@end
