/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDMIDISystemProblem.h"
#include <errno.h>

/* alsa-lib hardcodes this path (ALSA_DEVICE_DIRECTORY "seq"); alsa-seq-server
 * creates the same node on the BSDs. */
NSString * const NMDSequencerDevice = @"/dev/snd/seq";

NMDSequencerProvider NMDSequencerProviderOfThisSystem(void)
{
#if defined(__linux__)
  return NMDSequencerProviderKernel;
#else
  return NMDSequencerProviderCUSEServer;
#endif
}

MIDINetworkMIDISystem *NMDMIDISystemForSequencerOpenFailure(int errnum,
  NSString *detail, NMDSequencerProvider provider, BOOL haveCUSE)
{
  NSString *problem;

  switch (errnum)
    {
      /* ENODEV/ENXIO: a node is there but nothing serves it, which is the
       * same situation for the user as no node at all. */
      case ENOENT:
      case ENODEV:
      case ENXIO:
        if (provider == NMDSequencerProviderKernel)
          problem = MIDINetworkMIDIProblemSequencerModuleMissing;
        else if (!haveCUSE)
          problem = MIDINetworkMIDIProblemKernelLacksCUSE;
        else
          problem = MIDINetworkMIDIProblemSequencerServerNotRunning;
        return [MIDINetworkMIDISystem unavailableSystemWithProblem: problem
          device: NMDSequencerDevice detail: nil];
      case EACCES:
      case EPERM:
        return [MIDINetworkMIDISystem unavailableSystemWithProblem:
            MIDINetworkMIDIProblemPermissionDenied
          device: NMDSequencerDevice detail: nil];
      default:
        return [MIDINetworkMIDISystem unavailableSystemWithProblem:
            MIDINetworkMIDIProblemOpenFailed
          device: NMDSequencerDevice detail: detail];
    }
}
