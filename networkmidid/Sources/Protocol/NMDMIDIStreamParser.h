/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Turns a MIDI byte stream, as it arrives from a local port in arbitrary
 * pieces, into complete messages: running status is expanded, real-time
 * bytes inside other messages come out on their own, and a sysex comes out
 * once, whole, however many pieces it arrived in.
 */
@interface NMDMIDIStreamParser : NSObject

/* A sysex longer than this is dropped. */
@property (nonatomic) NSUInteger maxSysexLength;

/* Number of sysex messages dropped for being too long */
@property (nonatomic, readonly) NSUInteger droppedSysex;

- (NSArray *) messagesFromBytes: (const uint8_t *)bytes length: (NSUInteger)len;

- (void) reset;

@end
