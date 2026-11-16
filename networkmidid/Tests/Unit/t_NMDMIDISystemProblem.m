/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Which reason networkmidid reports when the ALSA sequencer cannot be
 * opened: it depends on the error and on who provides /dev/snd/seq on this
 * system (the Linux kernel, or alsa-seq-server through cuse on the BSDs). */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "NMDMIDISystemProblem.h"
#include <errno.h>

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  MIDINetworkMIDISystem *s;

  START_SET("missing device")
  s = NMDMIDISystemForSequencerOpenFailure(ENOENT, @"No such file or directory",
    NMDSequencerProviderKernel, NO);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemSequencerModuleMissing,
    "on Linux the snd-seq module is missing");
  PASS_EQUAL(s.device, @"/dev/snd/seq", "the device is named");
  PASS(!s.available, "and the system is unavailable");
  s = NMDMIDISystemForSequencerOpenFailure(ENOENT, @"No such file or directory",
    NMDSequencerProviderCUSEServer, YES);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemSequencerServerNotRunning,
    "on a BSD with cuse alsa-seq-server is not running");
  s = NMDMIDISystemForSequencerOpenFailure(ENOENT, @"No such file or directory",
    NMDSequencerProviderCUSEServer, NO);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemKernelLacksCUSE,
    "on a BSD without /dev/cuse the kernel is the reason");
  s = NMDMIDISystemForSequencerOpenFailure(ENODEV, @"No such device",
    NMDSequencerProviderKernel, NO);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemSequencerModuleMissing,
    "a device node without a driver counts as missing too");
  END_SET("missing device")

  START_SET("other failures")
  s = NMDMIDISystemForSequencerOpenFailure(EACCES, @"Permission denied",
    NMDSequencerProviderCUSEServer, YES);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemPermissionDenied, "no permission");
  s = NMDMIDISystemForSequencerOpenFailure(EPERM, @"Operation not permitted",
    NMDSequencerProviderKernel, NO);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemPermissionDenied, "EPERM is no permission as well");
  s = NMDMIDISystemForSequencerOpenFailure(EIO, @"Input/output error",
    NMDSequencerProviderKernel, NO);
  PASS_EQUAL(s.problem, MIDINetworkMIDIProblemOpenFailed, "anything else is a failed open");
  PASS_EQUAL(s.detail, @"Input/output error", "with the system's reason");
  END_SET("other failures")

  [arp release];
  return 0;
}
