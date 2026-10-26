/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* What the MIDI pane shows for a given backend state, selection and error:
   rows, selection fallbacks, enabled buttons, routing pop-ups, status. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDIPaneViewState.h"
#import "MIDINetworkFakeBackend.h"

static MIDIPaneViewState *View(id<MIDINetworkBackend> b, MIDIPaneSelection *sel, NSError *err)
{
    return [MIDIPaneViewState viewStateWithBackend:b selection:sel lastError:err];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("no service")
    NSError *why = MIDINetworkMakeError(MIDINetworkErrorUnavailable, @"The network MIDI service is not installed.");
    MIDINetworkUnavailableBackend *u = [[[MIDINetworkUnavailableBackend alloc] initWithReason:why] autorelease];
    MIDIPaneViewState *v = View(u, nil, nil);
    PASS(!v.canAddSession && !v.canAddHost && !v.detailsEnabled && !v.routingEnabled,
         "without a service nothing can be changed");
    PASS_EQUAL(v.statusText, @"The network MIDI service is not installed.", "the status says why");
    PASS(v.statusIsError, "as an error");
    PASS(v.selectedSessionRow == -1 && [v.sessionRows count] == 0, "no rows, no selection");
    END_SET("no service")

    START_SET("MIDI system unavailable")
    MIDINetworkMIDISystem *down = [MIDINetworkMIDISystem
        unavailableSystemWithProblem:MIDINetworkMIDIProblemSequencerServerNotRunning
                              device:@"/dev/snd/seq" detail:nil];
    MIDINetworkUnavailableBackend *u = [[[MIDINetworkUnavailableBackend alloc] initWithReason:[down error]] autorelease];
    MIDIPaneViewState *v = View(u, nil, nil);
    PASS_EQUAL(v.statusText,
               @"Network MIDI is unavailable: the ALSA sequencer (/dev/snd/seq) is missing. alsa-seq-server is not running.",
               "the status line gives the daemon's specific reason");
    PASS(v.statusIsError, "as an error");
    PASS(!v.canAddSession && !v.canRemoveSession && !v.detailsEnabled && !v.canAddHost
         && !v.canConnect && !v.canDisconnect && !v.routingEnabled,
         "and every session control is disabled");
    END_SET("MIDI system unavailable")

    MIDINetworkFakeBackend *b = [[[MIDINetworkFakeBackend alloc] initWithTimers:NO] autorelease];

    START_SET("daemon not running")
    MIDIPaneViewState *v = View(b, nil, nil);
    PASS_EQUAL(v.statusText, @"The network MIDI service is not running.", "a stopped service is named as such");
    PASS(!v.canAddSession, "and sessions cannot be added");
    END_SET("daemon not running")

    [b start];
    MIDINetworkSession *first = [MIDIPaneViewState proposedSessionForBackend:b];
    [b addSession:first error:NULL];
    MIDINetworkSession *second = [MIDIPaneViewState proposedSessionForBackend:b];
    [b addSession:second error:NULL];

    START_SET("sessions")
    PASS_EQUAL(first.name, MIDINetworkMachineName(), "the first proposed session is named after the machine");
    PASS_EQUAL(first.advertisedName, MIDINetworkMachineName(), "and peers see the machine's name");
    PASS(first.port == 5004 && second.port == 5006, "proposed sessions get free port pairs");
    PASS_EQUAL(second.name, [MIDINetworkMachineName() stringByAppendingString:@" 2"], "the second one is numbered");

    MIDIPaneViewState *v = View(b, nil, nil);
    PASS(v.selectedSessionRow == 0 && [v.selection.sessionIdentifier isEqual:first.identifier],
         "with nothing selected the first session is selected");
    PASS_EQUAL(v.statusText, @"Simulated network MIDI service (for development).",
               "the simulation is labelled as such");
    PASS(!v.statusIsError, "which is not an error");
    PASS(v.canAddSession && v.canRemoveSession && v.detailsEnabled, "a selected session can be edited and removed");

    MIDIPaneSelection *sel = [[MIDIPaneSelection new] autorelease];
    sel.sessionIdentifier = second.identifier;
    v = View(b, sel, nil);
    PASS(v.selectedSessionRow == 1, "a selected session is found by identifier");
    PASS_EQUAL(v.localName, second.name, "its local name is shown");
    PASS_EQUAL(v.portText, @"5006", "its port is shown");
    PASS(v.policyIndex == MIDINetworkConnectionPolicyAnyone && [v.policyTitles count] == 3,
         "the policy pop-up has three choices, Anyone selected");
    MIDIPaneRow *row = [v.sessionRows objectAtIndex:1];
    PASS(!row.checked, "the session's check box is off");

    sel.sessionIdentifier = @"gone";
    v = View(b, sel, nil);
    PASS(v.selectedSessionRow == 0, "a session that disappeared falls back to the first one");
    END_SET("sessions")

    START_SET("directory and connecting")
    [b advanceSimulation];
    MIDIPaneSelection *sel = [[MIDIPaneSelection new] autorelease];
    sel.sessionIdentifier = first.identifier;
    MIDIPaneViewState *v = View(b, sel, nil);
    PASS([v.directoryRows count] == 3 && v.selectedHostRow == -1, "discovered hosts are listed, none selected");
    PASS(!v.canConnect && !v.canRemoveHost, "without a host nothing can be connected or removed");
    MIDIPaneRow *hostRow = [v.directoryRows objectAtIndex:2];
    PASS_EQUAL(hostRow.title, @"Studio Laptop", "rows are sorted by name");
    PASS_EQUAL(hostRow.detail, @"192.168.1.20", "the address is the detail");
    sel.hostIdentifier = hostRow.identifier;
    v = View(b, sel, nil);
    PASS(v.selectedHostRow == 2, "the selected host is found");
    PASS(!v.canRemoveHost, "a discovered host cannot be removed");
    PASS(!v.canConnect, "Connect stays off while the session is off");
    [b setEnabled:YES forSessionWithIdentifier:first.identifier error:NULL];
    v = View(b, sel, nil);
    PASS(v.canConnect, "and comes on with the session");

    [b connectSessionWithIdentifier:first.identifier toHostWithIdentifier:hostRow.identifier error:NULL];
    v = View(b, sel, nil);
    PASS([v.participantRows count] == 1, "the invited peer is listed");
    PASS_EQUAL([[v.participantRows objectAtIndex:0] detail], @"Connecting...", "as connecting");
    PASS(!v.canDisconnect, "nothing selected, nothing to disconnect");
    [b advanceSimulation];
    v = View(b, sel, nil);
    MIDIPaneRow *peer = [v.participantRows objectAtIndex:0];
    PASS([peer.detail hasSuffix:@" ms"], "once connected the latency is shown in ms");
    sel.participantIdentifier = peer.identifier;
    v = View(b, sel, nil);
    PASS(v.selectedParticipantRow == 0 && v.canDisconnect, "a selected participant can be disconnected");

    sel.sessionIdentifier = second.identifier;
    v = View(b, sel, nil);
    PASS([v.participantRows count] == 0 && v.selection.participantIdentifier == nil,
         "another session shows its own (no) participants and drops the stale selection");

    MIDINetworkHost *manual = [MIDINetworkHost manualHostWithName:@"Far Away" address:@"10.8.0.2" port:5004];
    [b addManualHost:manual error:NULL];
    sel.hostIdentifier = manual.identifier;
    v = View(b, sel, nil);
    PASS(v.canRemoveHost, "a manual host can be removed");
    END_SET("directory and connecting")

    START_SET("routing")
    MIDIPaneSelection *sel = [[MIDIPaneSelection new] autorelease];
    sel.sessionIdentifier = first.identifier;
    MIDIPaneViewState *v = View(b, sel, nil);
    NSArray *wantIn = @[ @"None", @"USB Keyboard", @"MIDI Through" ];
    NSArray *wantOut = @[ @"None", @"Software Synth", @"MIDI Through" ];
    PASS_EQUAL(v.inputPortTitles, wantIn, "From offers None and the ports that send");
    PASS_EQUAL(v.outputPortTitles, wantOut, "To offers None and the ports that receive");
    PASS(v.inputPortIndex == 0 && v.outputPortIndex == 0 && v.routingEnabled, "an unrouted session shows None twice");
    [b setRoute:[MIDINetworkRoute routeForSession:first.identifier inputPort:@"fake:through"
                                       outputPort:@"fake:synth"] error:NULL];
    v = View(b, sel, nil);
    PASS(v.inputPortIndex == 2 && v.outputPortIndex == 1, "a route selects its ports");
    PASS_EQUAL([v.inputPortIdentifiers objectAtIndex:v.inputPortIndex], @"fake:through",
               "the identifiers run parallel to the titles");

    MIDINetworkBaseBackend *dup = [[MIDINetworkBaseBackend new] autorelease];
    [dup.state setLocalPorts:@[ [MIDINetworkPort portWithIdentifier:@"20:0" name:@"USB MIDI" canSend:YES canReceive:YES],
                                [MIDINetworkPort portWithIdentifier:@"24:0" name:@"USB MIDI" canSend:YES canReceive:YES] ]];
    v = View(dup, nil, nil);
    NSArray *wantDup = @[ @"None", @"USB MIDI (20:0)", @"USB MIDI (24:0)" ];
    PASS_EQUAL(v.inputPortTitles, wantDup, "ports sharing a name are told apart by identifier");
    END_SET("routing")

    START_SET("errors and status")
    NSError *e = MIDINetworkMakeStandardError(MIDINetworkErrorPortInUse);
    MIDIPaneViewState *v = View(b, nil, e);
    PASS_EQUAL(v.statusText, [e localizedDescription], "the last error is shown in the status line");
    PASS(v.statusIsError, "as an error");
    [b setSimulatedDaemonRunning:NO];
    v = View(b, nil, e);
    PASS_EQUAL(v.statusText, @"The network MIDI service is not running.", "a stopped service beats an old error");
    PASS(!v.canRemoveSession && !v.detailsEnabled && !v.canConnect && !v.routingEnabled,
         "and every control is off while it is stopped");
    END_SET("errors and status")

    [arp release];
    return 0;
}
