/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The factory's choice, and the networkmidid client against an in-process
   daemon that speaks the control interface (MIDINetworkControl.h). The
   test daemon doubles as a reference for networkmidid's side. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "MIDINetworkBackendFactory.h"
#import "MIDINetworkFakeBackend.h"
#import "MIDINetworkTestSupport.h"

/* A minimal daemon: one MIDINetworkState, every change answered with the
   sections it touched and pushed to the registered clients. */
@interface TestDaemon : NSObject <MIDINetworkDaemonControl>
{
@public
    MIDINetworkState *state;
    NSMutableArray *clients;
    int version;
    BOOL raiseTimeout;
}
@end

@implementation TestDaemon
- (id)init
{
    if ((self = [super init])) {
        state = [MIDINetworkState new];
        clients = [NSMutableArray new];
        version = MIDINETWORK_CONTROL_PROTOCOL_VERSION;
    }
    return self;
}
- (void)dealloc
{
    [state release];
    [clients release];
    [super dealloc];
}
- (int)protocolVersion { return version; }
- (bycopy NSDictionary *)snapshot { return [state propertyList]; }
- (void)registerClient:(id<MIDINetworkDaemonClient>)client { [clients addObject:client]; }
- (void)unregisterClient:(id<MIDINetworkDaemonClient>)client { [clients removeObject:client]; }
- (NSDictionary *)reply:(BOOL)ok error:(NSError *)error sections:(NSArray *)keys
{
    if (raiseTimeout) {
        [NSException raise:NSPortTimeoutException format:@"simulated timeout"];
    }
    if (!ok) {
        return MIDINetworkReplyWithError(error);
    }
    NSDictionary *all = [state propertyList];
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        [changes setObject:[all objectForKey:key] forKey:key];
    }
    return MIDINetworkReplyWithChanges(changes);
}
- (bycopy NSDictionary *)addSession:(bycopy NSDictionary *)plist
{
    NSError *e = nil;
    BOOL ok = [state addSession:[MIDINetworkSession sessionWithPropertyList:plist] error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeySessions ]];
}
- (bycopy NSDictionary *)removeSession:(bycopy NSString *)identifier
{
    NSError *e = nil;
    BOOL ok = [state removeSessionWithIdentifier:identifier error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeySessions, MIDINetworkStateKeyRoutes ]];
}
- (bycopy NSDictionary *)updateSession:(bycopy NSDictionary *)plist
{
    NSError *e = nil;
    BOOL ok = [state updateSession:[MIDINetworkSession sessionWithPropertyList:plist] error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeySessions ]];
}
- (bycopy NSDictionary *)setEnabled:(BOOL)enabled forSession:(bycopy NSString *)identifier
{
    NSError *e = nil;
    BOOL ok = [state setEnabled:enabled forSessionWithIdentifier:identifier error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeySessions, MIDINetworkStateKeyParticipants ]];
}
- (bycopy NSDictionary *)addManualHost:(bycopy NSDictionary *)plist
{
    NSError *e = nil;
    BOOL ok = [state addManualHost:[MIDINetworkHost hostWithPropertyList:plist] error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeyDirectory ]];
}
- (bycopy NSDictionary *)removeHost:(bycopy NSString *)identifier
{
    NSError *e = nil;
    BOOL ok = [state removeHostWithIdentifier:identifier error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeyDirectory ]];
}
- (bycopy NSDictionary *)connectSession:(bycopy NSString *)sessionIdentifier toHost:(bycopy NSString *)hostIdentifier
{
    NSError *e = nil;
    BOOL ok = [state validateConnectSession:sessionIdentifier toHost:hostIdentifier error:&e];
    return [self reply:ok error:e sections:@[]];
}
- (bycopy NSDictionary *)disconnectParticipant:(bycopy NSString *)participantIdentifier fromSession:(bycopy NSString *)sessionIdentifier
{
    NSError *e = nil;
    BOOL ok = [state removeParticipantWithIdentifier:participantIdentifier fromSession:sessionIdentifier error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeyParticipants ]];
}
- (bycopy NSDictionary *)setRoute:(bycopy NSDictionary *)plist
{
    NSError *e = nil;
    BOOL ok = [state setRoute:[MIDINetworkRoute routeWithPropertyList:plist] error:&e];
    return [self reply:ok error:e sections:@[ MIDINetworkStateKeyRoutes ]];
}
/* What networkmidid does when the network changes something. */
- (void)push:(NSArray *)keys
{
    NSDictionary *all = [state propertyList];
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        [changes setObject:[all objectForKey:key] forKey:key];
    }
    for (id<MIDINetworkDaemonClient> c in clients) {
        [c daemonDidChange:changes];
    }
}
@end

@interface TestConnector : NSObject <MIDINetworkDaemonConnector>
{
@public
    BOOL installed;
    TestDaemon *daemon;      /* nil = not running */
    void (^lost)(void);
    int connects;
}
@end

@implementation TestConnector
- (void)dealloc
{
    [daemon release];
    [lost release];
    [super dealloc];
}
- (BOOL)isDaemonInstalled { return installed; }
- (id<MIDINetworkDaemonControl>)connect { connects++; return daemon; }
- (void)watchControl:(id<MIDINetworkDaemonControl>)control lost:(void (^)(void))block
{
    [lost release];
    lost = [block copy];
}
- (void)disconnectControl:(id<MIDINetworkDaemonControl>)control { }
@end

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSError *error = nil;

    START_SET("factory")
    TestConnector *c = [[TestConnector new] autorelease];
    id<MIDINetworkBackend> b = MIDINetworkBackendCreate(nil, c);
    PASS([(id)b isKindOfClass:[MIDINetworkUnavailableBackend class]], "without networkmidid the backend is unavailable");
    PASS([b status] == MIDINetworkBackendStatusUnavailable
         && [[b statusError] code] == MIDINetworkErrorUnavailable, "and says so with the unavailable code");
    PASS([[[b statusError] localizedDescription] isEqual:@"The network MIDI service is not installed."],
         "the reason says that the service is missing, in generic words");
    PASS(![b addSession:[MIDINetworkSession sessionWithName:@"S" port:5004] error:&error]
         && [error code] == MIDINetworkErrorUnavailable, "every change is refused");
    c->installed = YES;
    b = MIDINetworkBackendCreate(nil, c);
    PASS([(id)b isKindOfClass:[MIDINetworkDaemonBackend class]], "with networkmidid installed its backend is chosen");
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning, "which is not running until it connects");
    b = MIDINetworkBackendCreate(MIDINetworkBackendNameSimulation, c);
    PASS([(id)b isKindOfClass:[MIDINetworkFakeBackend class]], "the simulation only when asked for by name");
    b = MIDINetworkBackendCreate(@"rtp", c);
    PASS([(id)b isKindOfClass:[MIDINetworkUnavailableBackend class]]
         && [[[b statusError] localizedDescription] rangeOfString:@"rtp"].location != NSNotFound,
         "an unknown name is refused, not replaced by another backend");
    END_SET("factory")

    START_SET("daemon backend")
    TestConnector *c = [[TestConnector new] autorelease];
    c->installed = YES;
    MNRecorder *rec = [[MNRecorder new] autorelease];
    MIDINetworkDaemonBackend *b = [[[MIDINetworkDaemonBackend alloc] initWithConnector:c] autorelease];
    b.retryInterval = 0;
    [b setDelegate:rec];
    [b start];
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning && c->connects == 1,
         "a daemon that does not answer leaves it not running");

    TestDaemon *d = [[TestDaemon new] autorelease];
    [d->state setLocalPorts:@[ [MIDINetworkPort portWithIdentifier:@"syn" name:@"Synth" canSend:NO canReceive:YES] ]];
    c->daemon = [d retain];
    [rec reset];
    [b start];
    PASS([b status] == MIDINetworkBackendStatusRunning && rec->status == 1, "once it answers the backend runs");
    PASS([d->clients count] == 1, "and registered itself for changes");
    PASS([[b localPorts] count] == 1 && rec->ports == 1, "the snapshot is loaded and announced");

    [rec reset];
    MIDINetworkSession *s = [MIDINetworkSession sessionWithName:@"Desk" port:5004];
    PASS([b addSession:s error:NULL], "a session is added through the daemon");
    PASS([[d->state sessions] count] == 1, "the daemon has it");
    PASS([[b sessions] count] == 1 && rec->sessions == 1, "the reply's changes are applied at once and notified");

    MIDINetworkSession *clash = [MIDINetworkSession sessionWithName:@"Other" port:5005];
    error = nil;
    PASS(![b addSession:clash error:&error] && [error code] == MIDINetworkErrorPortInUse,
         "the daemon's refusal arrives with its code");
    PASS([[error localizedDescription] length] > 0, "and its message");

    [rec reset];
    [d->state setEnabled:YES forSessionWithIdentifier:s.identifier error:NULL];
    MIDINetworkParticipant *p = [[MIDINetworkParticipant new] autorelease];
    p.identifier = @"peer"; p.name = @"Peer"; p.address = @"10.0.0.2:5004"; p.latency = 3; p.state = 1;
    [d->state addParticipant:p toSession:s.identifier error:NULL];
    [d push:@[ MIDINetworkStateKeySessions, MIDINetworkStateKeyParticipants ]];
    PASS([[b participantsForSessionWithIdentifier:s.identifier] count] == 1 && rec->participants == 1
         && rec->sessions == 1, "pushed changes reach the backend and the delegate");
    PASS(rec->directory == 0, "sections that were not pushed are not announced");

    [rec reset];
    [b daemonDidChange:@{ MIDINetworkStateKeySessions: @[ @{ @"name": @"broken" } ] }];
    PASS([[b sessions] count] == 1 && rec->errors == 1, "a malformed push is rejected and reported");

    [b daemonDidEncounterError:@{ MIDINetworkErrorKeyCode: @(MIDINetworkErrorPeerRejected),
                                  MIDINetworkErrorKeyMessage: @"declined" }];
    PASS([rec->lastError code] == MIDINetworkErrorPeerRejected, "asynchronous daemon errors are passed on");

    d->raiseTimeout = YES;
    error = nil;
    PASS(![b removeSessionWithIdentifier:s.identifier error:&error] && [error code] == MIDINetworkErrorTimeout,
         "a call that times out is reported as timeout");
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning && [[b sessions] count] == 0,
         "and the backend stops showing stale sessions");
    d->raiseTimeout = NO;
    [b start];
    PASS([b status] == MIDINetworkBackendStatusRunning
         && [[b sessions] count] == [[d->state sessions] count], "it reconnects and shows what the daemon has");

    [rec reset];
    c->lost();
    PASS([b status] == MIDINetworkBackendStatusDaemonNotRunning && rec->status == 1 && rec->sessions == 1,
         "a dying connection is noticed and announced");

    d->version = MIDINETWORK_CONTROL_PROTOCOL_VERSION + 1;
    [b start];
    PASS([b status] == MIDINetworkBackendStatusUnavailable, "a daemon of another protocol version is not used");
    [b stop];
    END_SET("daemon backend")

    START_SET("replies")
    PASS(MIDINetworkErrorFromReply(@{}) == nil, "an empty reply is success");
    PASS([MIDINetworkErrorFromReply(nil) code] == MIDINetworkErrorInvalidArgument, "nil is a malformed reply");
    NSError *e = MIDINetworkMakeError(MIDINetworkErrorPortInUse, @"taken");
    NSError *back = MIDINetworkErrorFromReply(MIDINetworkReplyWithError(e));
    PASS([back code] == MIDINetworkErrorPortInUse && [[back localizedDescription] isEqual:@"taken"],
         "an error survives the reply form");
    PASS([MIDINetworkDaemonServiceName() hasPrefix:@"io.github.gershwin-desktop.networkmidid."],
         "the service name is per user under our identifier");
    END_SET("replies")

    [arp release];
    return 0;
}
