/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMMIDIPorts.h"

/* libasound rather than raw ioctls on /dev/snd/seq: the library is what
 * alsa-seq-server is tested against on FreeBSD, it converts between
 * sequencer events and MIDI bytes, and it shields us from the ioctl ABI
 * versions of the kernel and of the cuse emulation. */
@interface GMALSASequencer : NSObject <GMMIDIPorts>
- (instancetype) initWithClientName: (NSString *)name error: (NSError **)error;
@end
