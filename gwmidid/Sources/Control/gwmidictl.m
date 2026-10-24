/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/*
 * gwmidictl: talks to the running gwmidid of the current user over the
 * same control interface as the MIDI pane, for scripts, tests and the
 * terminal.  Sessions, hosts and participants are named by name here; the
 * identifiers are looked up in the daemon's snapshot.
 */
#import <Foundation/Foundation.h>
#import "MIDINetworkControl.h"
#import "MIDINetworkState.h"
#import "MIDINetworkBackend.h"

static void usage(void)
{
  fprintf(stderr,
    "usage: gwmidictl status\n"
    "       gwmidictl add <name> <port> [<advertised name>]\n"
    "       gwmidictl remove <session>\n"
    "       gwmidictl enable|disable <session>\n"
    "       gwmidictl policy <session> anyone|directory|nobody\n"
    "       gwmidictl host <name> <address> <port>\n"
    "       gwmidictl unhost <host>\n"
    "       gwmidictl connect <session> <host>\n"
    "       gwmidictl disconnect <session> <participant name or identifier>\n"
    "       gwmidictl route <session> <input port id|-> <output port id|->\n");
  exit(2);
}

static void fail(NSString *msg)
{
  fprintf(stderr, "gwmidictl: %s\n", [msg UTF8String]);
  exit(1);
}

static void check(NSDictionary *reply)
{
  NSError *e = MIDINetworkErrorFromReply(reply);
  if (e != nil)
    fail([NSString stringWithFormat: @"%@ (code %ld)",
      [e localizedDescription], (long)[e code]]);
}

static MIDINetworkSession *sessionNamed(MIDINetworkState *st, NSString *n)
{
  for (MIDINetworkSession *s in [st sessions])
    if ([s.name isEqual: n] || [s.identifier isEqual: n]) return s;
  fail([NSString stringWithFormat: @"no session \"%@\"", n]);
  return nil;
}

static MIDINetworkHost *hostNamed(MIDINetworkState *st, NSString *n)
{
  for (MIDINetworkHost *h in [st directory])
    if ([h.name isEqual: n] || [h.identifier isEqual: n]) return h;
  fail([NSString stringWithFormat: @"no host \"%@\" in the directory", n]);
  return nil;
}

/* One line per object, key=value, so both people and scripts can read it. */
static void printStatus(MIDINetworkState *st)
{
  for (MIDINetworkSession *s in [st sessions])
    {
      MIDINetworkRoute *r = [st routeForSessionWithIdentifier: s.identifier];
      printf("session \"%s\" advertised=\"%s\" port=%lu enabled=%s policy=%s"
        " input=%s output=%s id=%s\n", [s.name UTF8String],
        [s.advertisedName UTF8String], (unsigned long)s.port,
        s.enabled ? "yes" : "no",
        [MIDINetworkConnectionPolicyName(s.policy) UTF8String],
        r.inputPortIdentifier ? [r.inputPortIdentifier UTF8String] : "-",
        r.outputPortIdentifier ? [r.outputPortIdentifier UTF8String] : "-",
        [s.identifier UTF8String]);
      for (MIDINetworkParticipant *p in
           [st participantsForSessionWithIdentifier: s.identifier])
        printf("  participant %s name=\"%s\" address=%s state=%s latency-ms=%.2f\n",
          [p.identifier UTF8String], [p.name UTF8String], [p.address UTF8String],
          [p isConnected] ? "connected" : "inviting", p.latency);
    }
  for (MIDINetworkHost *h in [st directory])
    printf("host \"%s\" address=%s port=%lu source=%s id=%s\n",
      [h.name UTF8String], [h.address UTF8String], (unsigned long)h.port,
      [h isManual] ? "manual" : "discovered", [h.identifier UTF8String]);
  for (MIDINetworkPort *p in [st localPorts])
    printf("port %s name=\"%s\" send=%s receive=%s\n", [p.identifier UTF8String],
      [p.name UTF8String], p.canSend ? "yes" : "no", p.canReceive ? "yes" : "no");
}

int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      NSArray *a = [[NSProcessInfo processInfo] arguments];
      NSUInteger n = [a count];
      NSString *cmd;
      id<MIDINetworkDaemonControl> d;
      MIDINetworkState *st;

      if (n < 2) usage();
      cmd = [a objectAtIndex: 1];
      d = (id<MIDINetworkDaemonControl>)[NSConnection
        rootProxyForConnectionWithRegisteredName: MIDINetworkDaemonServiceName()
                                            host: @""
                                 usingNameServer: [NSMessagePortNameServer sharedInstance]];
      if (d == nil) fail(@"gwmidid is not running for this user");
      [(NSDistantObject *)d setProtocolForProxy: @protocol(MIDINetworkDaemonControl)];
      if ([d protocolVersion] != MIDINETWORK_CONTROL_PROTOCOL_VERSION)
        fail(@"gwmidid speaks another version of the control interface");
      st = [MIDINetworkState stateWithPropertyList: [d snapshot]];
      if (st == nil) fail(@"gwmidid sent a snapshot that is not understood");

#define ARG(i) [a objectAtIndex: (i)]
      if ([cmd isEqual: @"status"] && n == 2)
        printStatus(st);
      else if ([cmd isEqual: @"add"] && (n == 4 || n == 5))
        {
          MIDINetworkSession *s = [MIDINetworkSession
            sessionWithName: ARG(2) port: (NSUInteger)[ARG(3) integerValue]];
          s.advertisedName = (n == 5) ? ARG(4) : ARG(2);
          check([d addSession: [s propertyList]]);
        }
      else if ([cmd isEqual: @"remove"] && n == 3)
        check([d removeSession: sessionNamed(st, ARG(2)).identifier]);
      else if (([cmd isEqual: @"enable"] || [cmd isEqual: @"disable"]) && n == 3)
        check([d setEnabled: [cmd isEqual: @"enable"]
                 forSession: sessionNamed(st, ARG(2)).identifier]);
      else if ([cmd isEqual: @"policy"] && n == 4)
        {
          MIDINetworkSession *s = [sessionNamed(st, ARG(2)) copy];
          MIDINetworkConnectionPolicy p;
          if (!MIDINetworkConnectionPolicyFromName(ARG(3), &p))
            fail(@"policy must be anyone, directory or nobody");
          s.policy = p;
          check([d updateSession: [s propertyList]]);
        }
      else if ([cmd isEqual: @"host"] && n == 5)
        check([d addManualHost: [[MIDINetworkHost manualHostWithName: ARG(2)
          address: ARG(3) port: (NSUInteger)[ARG(4) integerValue]] propertyList]]);
      else if ([cmd isEqual: @"unhost"] && n == 3)
        check([d removeHost: hostNamed(st, ARG(2)).identifier]);
      else if ([cmd isEqual: @"connect"] && n == 4)
        check([d connectSession: sessionNamed(st, ARG(2)).identifier
                         toHost: hostNamed(st, ARG(3)).identifier]);
      else if ([cmd isEqual: @"disconnect"] && n == 4)
        {
          MIDINetworkSession *s = sessionNamed(st, ARG(2));
          NSString *pid = nil;
          for (MIDINetworkParticipant *p in
               [st participantsForSessionWithIdentifier: s.identifier])
            if ([p.name isEqual: ARG(3)] || [p.identifier isEqual: ARG(3)])
              pid = p.identifier;
          if (pid == nil) fail(@"no such participant");
          check([d disconnectParticipant: pid fromSession: s.identifier]);
        }
      else if ([cmd isEqual: @"route"] && n == 5)
        {
          NSString *in = [ARG(3) isEqual: @"-"] ? nil : ARG(3);
          NSString *out = [ARG(4) isEqual: @"-"] ? nil : ARG(4);
          check([d setRoute: [[MIDINetworkRoute
            routeForSession: sessionNamed(st, ARG(2)).identifier
                  inputPort: in outputPort: out] propertyList]]);
        }
      else
        usage();
#undef ARG
    }
  return 0;
}
