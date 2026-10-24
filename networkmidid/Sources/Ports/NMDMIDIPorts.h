/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

@protocol NMDMIDIPorts;

@protocol NMDMIDIPortsDelegate <NSObject>
/* Complete MIDI messages an application wrote to one of our ports */
- (void) ports: (id<NMDMIDIPorts>)ports
  didReceiveMessages: (NSArray *)messages
              onPort: (int)port;
/* A port of another program appeared, disappeared or changed. */
- (void) portsDidChangeLocalPorts: (id<NMDMIDIPorts>)ports;
@end

/* Keys of the dictionaries -localPorts returns */
extern NSString * const NMDLocalPortIdentifier;   /* "client:port" */
extern NSString * const NMDLocalPortName;
extern NSString * const NMDLocalPortCanSend;      /* it produces MIDI */
extern NSString * const NMDLocalPortCanReceive;   /* it consumes MIDI */

/* The local side: one MIDI port per session that applications connect to.
 * ALSA sequencer on Linux and on FreeBSD/NextBSD (through alsa-seq-server);
 * OpenBSD will get a sndio implementation of the same protocol. */
@protocol NMDMIDIPorts <NSObject>
@property (nonatomic, weak) id<NMDMIDIPortsDelegate> delegate;
/* Returns the port number, or -1 with an error. */
- (int) createPortNamed: (NSString *)name error: (NSError **)error;
- (void) removePort: (int)port;
- (void) renamePort: (int)port to: (NSString *)name;
/* Sends to every application connected to the port. */
- (void) sendMessages: (NSArray *)messages fromPort: (int)port;
/* The ports of other programs that a session can be routed to or from;
 * our own session ports are not among them. */
- (NSArray *) localPorts;
/* input: the local port plays into our port; otherwise our port plays
 * into the local port. */
- (BOOL) connectPort: (int)port
         toLocalPort: (NSString *)identifier
               input: (BOOL)input
               error: (NSError **)error;
- (void) disconnectPort: (int)port
          fromLocalPort: (NSString *)identifier
                  input: (BOOL)input;
/* "client:port" as aconnect and other tools take it */
- (NSString *) addressOfPort: (int)port;
/* Client number and name, for the control interface and logs */
- (NSString *) portLayerDescription;
- (void) close;
@end

/* The port layer of this platform, or nil with an error when there is none
 * or it cannot be opened (no sequencer device, no permission). */
id<NMDMIDIPorts> NMDMIDIPortsOpen(NSString *clientName, NSError **error);
