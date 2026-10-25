/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The state of the computer's MIDI system as networkmidid reports it: the
   property list round trip, the sentence for each problem, the error the
   backend shows, and how the snapshot and the daemon backend carry it. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkModels.h"
#import "MIDINetworkState.h"
#import "MIDINetworkBackend.h"

static NSString *Upper(NSString *format)
{
    return [format uppercaseString];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("model")
    MIDINetworkMIDISystem *ok = [MIDINetworkMIDISystem availableSystem];
    PASS(ok.available && ok.problem == nil, "the available system has no problem");
    PASS_EQUAL([ok propertyList], (@{ @"available": @YES }), "and says only that");

    MIDINetworkMIDISystem *bad = [MIDINetworkMIDISystem
        unavailableSystemWithProblem:MIDINetworkMIDIProblemSequencerServerNotRunning
                              device:@"/dev/snd/seq" detail:nil];
    PASS(!bad.available, "an unavailable system");
    NSDictionary *plist = [bad propertyList];
    PASS_EQUAL([plist objectForKey:@"problem"], @"sequencerServerNotRunning", "names its problem");
    PASS_EQUAL([plist objectForKey:@"device"], @"/dev/snd/seq", "and the device");
    MIDINetworkMIDISystem *back = [MIDINetworkMIDISystem midiSystemWithPropertyList:plist];
    PASS([back isEqual:bad] && [back hash] == [bad hash], "it survives the round trip");
    PASS([MIDINetworkMIDISystem midiSystemWithPropertyList:@{ @"available": @NO }] == nil,
         "unavailable without a problem is malformed");
    PASS([MIDINetworkMIDISystem midiSystemWithPropertyList:@{ @"available": @"yes" }] == nil,
         "a non-boolean flag is malformed");
    PASS([MIDINetworkMIDISystem midiSystemWithPropertyList:@"x"] == nil, "a non-dictionary is malformed");
    PASS(![ok isEqual:bad], "available and unavailable differ");
    END_SET("model")

    START_SET("sentences")
    MIDINetworkMIDISystem *s;
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemSequencerServerNotRunning
                                                     device:@"/dev/snd/seq" detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: the ALSA sequencer (/dev/snd/seq) is missing. alsa-seq-server is not running.",
               "a BSD without alsa-seq-server");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemKernelLacksCUSE
                                                     device:@"/dev/snd/seq" detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: the ALSA sequencer (/dev/snd/seq) is missing. alsa-seq-server cannot run because this kernel has no cuse support.",
               "a BSD kernel without cuse");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemSequencerModuleMissing
                                                     device:@"/dev/snd/seq" detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: the ALSA sequencer (/dev/snd/seq) is missing. The snd-seq kernel module is not loaded.",
               "Linux without snd-seq");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemPermissionDenied
                                                     device:@"/dev/snd/seq" detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: there is no permission to open the ALSA sequencer (/dev/snd/seq).",
               "no permission");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemOpenFailed
                                                     device:@"/dev/snd/seq" detail:@"Input/output error"];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: the ALSA sequencer (/dev/snd/seq) cannot be opened (Input/output error).",
               "any other failure carries the system's reason");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemNoPortLayer device:nil detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: this system has no MIDI port layer for it yet.",
               "a system without a port layer");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:@"somethingNew" device:nil detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:nil],
               @"Network MIDI is unavailable: the computer's MIDI system cannot be used.",
               "a problem this version does not know still gets a sentence");
    s = [MIDINetworkMIDISystem unavailableSystemWithProblem:MIDINetworkMIDIProblemSequencerServerNotRunning
                                                     device:@"/dev/snd/seq" detail:nil];
    PASS_EQUAL([s descriptionWithTranslator:^(NSString *f) { return Upper(f); }],
               @"NETWORK MIDI IS UNAVAILABLE: THE ALSA SEQUENCER (/dev/snd/seq) IS MISSING. ALSA-SEQ-SERVER IS NOT RUNNING.",
               "the translator gets the fixed format, the device is inserted afterwards");

    NSError *e = [s error];
    PASS([e code] == MIDINetworkErrorMIDISystemUnavailable && [[e domain] isEqual:MIDINetworkErrorDomain],
         "the error has its own code");
    PASS_EQUAL([e localizedDescription], [s descriptionWithTranslator:nil], "and the English sentence");
    PASS_EQUAL([[e userInfo] objectForKey:MIDINetworkMIDISystemErrorKey], s, "and carries the system for translation");
    END_SET("sentences")

    START_SET("snapshot")
    MIDINetworkState *st = [[MIDINetworkState new] autorelease];
    PASS(st.midiSystem.available, "a new state has an available MIDI system");
    MIDINetworkMIDISystem *down = [MIDINetworkMIDISystem
        unavailableSystemWithProblem:MIDINetworkMIDIProblemKernelLacksCUSE device:@"/dev/snd/seq" detail:nil];
    st.midiSystem = down;
    NSDictionary *snap = [st propertyList];
    PASS([snap objectForKey:MIDINetworkStateKeyMIDISystem] != nil, "the snapshot has a midiSystem section");
    MIDINetworkState *copy = [MIDINetworkState stateWithPropertyList:snap];
    PASS([copy.midiSystem isEqual:down], "which survives the round trip");
    NSMutableDictionary *old = [[snap mutableCopy] autorelease];
    [old removeObjectForKey:MIDINetworkStateKeyMIDISystem];
    PASS([MIDINetworkState stateWithPropertyList:old].midiSystem.available,
         "a snapshot without the section means the MIDI system works");
    [old setObject:@{ @"available": @NO } forKey:MIDINetworkStateKeyMIDISystem];
    PASS([MIDINetworkState stateWithPropertyList:old] == nil, "a malformed section rejects the snapshot");
    END_SET("snapshot")

    [arp release];
    return 0;
}
