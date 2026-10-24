/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/* t_LiveControl - the client the MIDI pane uses, MIDINetworkDaemonBackend,
 * against the real gwmidid over Distributed Objects: the same steps as the
 * library's test against its in-process TestDaemon, plus what only a real
 * daemon does (sockets, invitations between two sessions, local ports). */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkDaemonBackend.h"
#import "MIDINetworkState.h"
#import "MIDINetworkTestSupport.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <string.h>
#include <unistd.h>

/* gwmidid is not installed while it is being tested; the real Distributed
 * Objects connection is used all the same. */
@interface UninstalledConnector : MIDINetworkDistributedObjectsConnector
@end
@implementation UninstalledConnector
- (BOOL)isDaemonInstalled { return YES; }
@end

static void Spin(NSTimeInterval s)
{
  [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: s]];
}

/* Runs the run loop until cond holds or the time is up. */
#define WAIT_FOR(cond, secs) do { \
    NSDate *_end = [NSDate dateWithTimeIntervalSinceNow: (secs)]; \
    while (!(cond) && [_end timeIntervalSinceNow] > 0) Spin(0.05); \
  } while (0)

static NSString * const kHostName = @"Second session";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSError *error = nil;
  MNRecorder *rec = [[MNRecorder new] autorelease];
  MIDINetworkDaemonBackend *b = [[[MIDINetworkDaemonBackend alloc]
    initWithConnector: [[UninstalledConnector new] autorelease]] autorelease];
  MIDINetworkSession *s1, *s2, *clash, *busy;
  MIDINetworkHost *h = nil;
  int blocker;

  b.retryInterval = 0;
  [b setDelegate: rec];
  [b start];
  PASS([b status] == MIDINetworkBackendStatusRunning,
    "the client connects to gwmidid and accepts its protocol version");
  PASS([[b sessions] count] == 0, "a fresh gwmidid has no sessions");
  PASS([[b localPorts] count] > 0, "it lists the local MIDI ports");

  s1 = [MIDINetworkSession sessionWithName: @"Live A" port: 25010];
  s1.advertisedName = @"gwmidid live A";
  PASS([b addSession: s1 error: &error] && [[b sessions] count] == 1,
    "a session is added; the reply's changes are applied at once");
  clash = [MIDINetworkSession sessionWithName: @"Live clash" port: 25011];
  clash.advertisedName = @"x";
  error = nil;
  PASS(![b addSession: clash error: &error]
    && [error code] == MIDINetworkErrorPortInUse,
    "a session on the port above another one is refused with portInUse");

  PASS([b setEnabled: YES forSessionWithIdentifier: s1.identifier error: &error]
    && [[b sessionWithIdentifier: s1.identifier] isEnabled],
    "enabling opens the session");

  /* A port held by another program */
  {
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(25021);
    blocker = socket(AF_INET, SOCK_DGRAM, 0);
    bind(blocker, (struct sockaddr *)&a, sizeof a);
  }
  busy = [MIDINetworkSession sessionWithName: @"Live busy" port: 25020];
  busy.advertisedName = @"gwmidid live busy";
  [b addSession: busy error: NULL];
  error = nil;
  PASS(![b setEnabled: YES forSessionWithIdentifier: busy.identifier error: &error]
    && [error code] == MIDINetworkErrorPortInUse
    && ![[b sessionWithIdentifier: busy.identifier] isEnabled],
    "a data port taken by another program: portInUse, the session stays off");
  close(blocker);
  [b removeSessionWithIdentifier: busy.identifier error: NULL];

  s2 = [MIDINetworkSession sessionWithName: @"Live B" port: 25040];
  s2.advertisedName = @"gwmidid live B";
  [b addSession: s2 error: NULL];
  [b setEnabled: YES forSessionWithIdentifier: s2.identifier error: NULL];

  error = nil;
  PASS([b addManualHost: [MIDINetworkHost manualHostWithName: kHostName
    address: @"127.0.0.1" port: 25040] error: &error],
    "a manual host is added");
  for (MIDINetworkHost *x in [b directory])
    if ([x.name isEqual: kHostName]) h = x;
  PASS(h != nil && [h isManual], "and listed as manual");
  error = nil;
  PASS(![b addManualHost: [MIDINetworkHost manualHostWithName: @"named"
    address: @"somewhere.local" port: 5004] error: &error]
    && [error code] == MIDINetworkErrorInvalidArgument,
    "a host name instead of an address is refused");

  [rec reset];
  PASS([b connectSessionWithIdentifier: s1.identifier
                  toHostWithIdentifier: h.identifier error: &error],
    "session A invites session B of the same gwmidid");
  WAIT_FOR([[b participantsForSessionWithIdentifier: s1.identifier] count] == 1
    && [[[b participantsForSessionWithIdentifier: s1.identifier] objectAtIndex: 0]
         isConnected]
    && [[b participantsForSessionWithIdentifier: s2.identifier] count] == 1, 5);
  {
    NSArray *pa = [b participantsForSessionWithIdentifier: s1.identifier];
    NSArray *pb = [b participantsForSessionWithIdentifier: s2.identifier];
    MIDINetworkParticipant *p = [pa count] ? [pa objectAtIndex: 0] : nil;
    PASS(p != nil && [p isConnected] && [p.name isEqual: @"gwmidid live B"]
      && [p.address isEqual: @"127.0.0.1:25040"],
      "A shows B as a connected participant, with name and address (pushed)");
    PASS([pb count] == 1 && [[[pb objectAtIndex: 0] name] isEqual: @"gwmidid live A"],
      "and B shows A");
    PASS(rec->participants > 0, "the delegate heard about it");
    WAIT_FOR([[[b participantsForSessionWithIdentifier: s1.identifier]
      objectAtIndex: 0] latency] >= 0, 3);
    PASS([[[b participantsForSessionWithIdentifier: s1.identifier]
      objectAtIndex: 0] latency] >= 0, "a latency is reported after clock sync");

    {
      MIDINetworkSession *u = [[b sessionWithIdentifier: s2.identifier] copy];
      u.policy = MIDINetworkConnectionPolicyNobody;
      PASS([b updateSession: u error: &error]
        && [[b participantsForSessionWithIdentifier: s2.identifier] count] == 1,
        "changing the policy keeps the participants");
      [u release];
    }
    PASS([b disconnectParticipantWithIdentifier: p.identifier
      fromSessionWithIdentifier: s1.identifier error: &error],
      "a participant is disconnected");
    WAIT_FOR([[b participantsForSessionWithIdentifier: s2.identifier] count] == 0, 3);
    PASS([[b participantsForSessionWithIdentifier: s1.identifier] count] == 0
      && [[b participantsForSessionWithIdentifier: s2.identifier] count] == 0,
      "both sides drop it (BY)");
  }

  [rec reset];
  [b connectSessionWithIdentifier: s1.identifier toHostWithIdentifier: h.identifier
                            error: NULL];
  WAIT_FOR(rec->errors > 0, 5);
  PASS([rec->lastError code] == MIDINetworkErrorPeerRejected,
    "an invitation to a session with policy nobody comes back as peerRejected");
  WAIT_FOR([[b participantsForSessionWithIdentifier: s1.identifier] count] == 0, 3);
  PASS([[b participantsForSessionWithIdentifier: s1.identifier] count] == 0,
    "and the inviting participant is gone");

  {
    MIDINetworkPort *thru = nil;
    for (MIDINetworkPort *p in [b localPorts])
      if (p.canReceive && p.canSend) { thru = p; break; }
    if (thru != nil)
      {
        PASS([b setRoute: [MIDINetworkRoute routeForSession: s1.identifier
          inputPort: thru.identifier outputPort: thru.identifier] error: &error]
          && [[[b routeForSessionWithIdentifier: s1.identifier]
               outputPortIdentifier] isEqual: thru.identifier],
          "a route to a local port (%s) is set", [thru.name UTF8String]);
      }
    error = nil;
    PASS(![b setRoute: [MIDINetworkRoute routeForSession: s1.identifier
      inputPort: @"999:9" outputPort: nil] error: &error]
      && [error code] == MIDINetworkErrorInvalidArgument,
      "a route to a port that does not exist is refused");
  }

  PASS([b setEnabled: NO forSessionWithIdentifier: s1.identifier error: &error]
    && ![[b sessionWithIdentifier: s1.identifier] isEnabled],
    "disabling closes the session");
  PASS([b removeSessionWithIdentifier: s1.identifier error: &error]
    && [b removeSessionWithIdentifier: s2.identifier error: &error]
    && [b removeHostWithIdentifier: h.identifier error: &error]
    && [[b sessions] count] == 0, "sessions and hosts are removed again");
  [b stop];

  [arp release];
  return 0;
}
