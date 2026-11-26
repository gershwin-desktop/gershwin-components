/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "MIDINetworkModels.h"

/* Who creates the sequencer device, which decides what is missing when
 * it is not there. */
typedef NS_ENUM(NSInteger, NMDSequencerProvider) {
  NMDSequencerProviderKernel,      /* Linux: the snd-seq module */
  NMDSequencerProviderCUSEServer   /* FreeBSD, NextBSD: alsa-seq-server through cuse */
};

/* The device alsa-lib opens for the sequencer on every system we support. */
extern NSString * const NMDSequencerDevice;

/* The provider of the system networkmidid was built for. */
NMDSequencerProvider NMDSequencerProviderOfThisSystem(void);

/* Why opening the sequencer failed, as the clients are told: errnum is the
 * positive errno, detail the system's text for it, haveCUSE whether
 * /dev/cuse exists (only asked on the BSDs). */
MIDINetworkMIDISystem *NMDMIDISystemForSequencerOpenFailure(int errnum,
  NSString *detail, NMDSequencerProvider provider, BOOL haveCUSE);
