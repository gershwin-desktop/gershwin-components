/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkFakeBackend.h"

NSString * const MIDINetworkFakeRejectingHostName = @"Busy Studio";

NSString * const MIDINetworkFakeOperationAddSession = @"addSession";
NSString * const MIDINetworkFakeOperationRemoveSession = @"removeSession";
NSString * const MIDINetworkFakeOperationUpdateSession = @"updateSession";
NSString * const MIDINetworkFakeOperationSetEnabled = @"setEnabled";
NSString * const MIDINetworkFakeOperationAddManualHost = @"addManualHost";
NSString * const MIDINetworkFakeOperationRemoveHost = @"removeHost";
NSString * const MIDINetworkFakeOperationConnect = @"connect";
NSString * const MIDINetworkFakeOperationDisconnect = @"disconnect";
NSString * const MIDINetworkFakeOperationSetRoute = @"setRoute";

/* An invitation that is answered on the next step. */
@interface MIDINetworkFakeInvitation : NSObject
@property (nonatomic, copy) NSString *sessionIdentifier;
@property (nonatomic, copy) NSString *participantIdentifier;
@property (nonatomic) BOOL rejects;
@end

@implementation MIDINetworkFakeInvitation
@end

@implementation MIDINetworkFakeBackend
{
    BOOL _useTimers;
    BOOL _started;
    BOOL _daemonRunning;
    BOOL _discovered;
    NSTimer *_timer;
    NSMutableDictionary *_failures;       /* operation -> NSNumber code */
    NSMutableArray *_invitations;
    uint32_t _random;
}

- (instancetype)init
{
    return [self initWithTimers:YES];
}

- (instancetype)initWithTimers:(BOOL)useTimers
{
    if ((self = [super init])) {
        _useTimers = useTimers;
        _daemonRunning = YES;
        _failures = [NSMutableDictionary dictionary];
        _invitations = [NSMutableArray array];
        /* Fixed seed: the same steps give the same latencies in every run. */
        _random = 12345;
        [self.state setLocalPorts:@[
            [MIDINetworkPort portWithIdentifier:@"fake:keyboard" name:@"USB Keyboard" canSend:YES canReceive:NO],
            [MIDINetworkPort portWithIdentifier:@"fake:synth" name:@"Software Synth" canSend:NO canReceive:YES],
            [MIDINetworkPort portWithIdentifier:@"fake:through" name:@"MIDI Through" canSend:YES canReceive:YES]
        ]];
        [self setStatus:MIDINetworkBackendStatusDaemonNotRunning
                  error:MIDINetworkMakeStandardError(MIDINetworkErrorDaemonNotRunning)];
    }
    return self;
}

- (void)dealloc
{
    [_timer invalidate];
}

- (NSString *)backendName
{
    return @"simulation";
}

- (void)start
{
    _started = YES;
    [self updateStatus];
    if (_useTimers && _timer == nil) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil repeats:YES];
    }
}

- (void)stop
{
    _started = NO;
    [_timer invalidate];
    _timer = nil;
}

- (void)timerFired:(NSTimer *)timer
{
    [self advanceSimulation];
}

- (void)updateStatus
{
    if (_daemonRunning) {
        [self setStatus:MIDINetworkBackendStatusRunning error:nil];
    } else {
        [self setStatus:MIDINetworkBackendStatusDaemonNotRunning
                  error:MIDINetworkMakeStandardError(MIDINetworkErrorDaemonNotRunning)];
    }
}

- (void)setSimulatedDaemonRunning:(BOOL)running
{
    _daemonRunning = running;
    [self updateStatus];
}

- (void)failNextOperation:(NSString *)operation withCode:(MIDINetworkErrorCode)code
{
    [_failures setObject:@(code) forKey:operation];
}

/* NO when the operation may not run: the daemon is down or a failure was
   injected for it. */
- (BOOL)mayPerform:(NSString *)operation error:(NSError **)error
{
    if ([self status] != MIDINetworkBackendStatusRunning) {
        return [self refuse:error];
    }
    NSNumber *code = [_failures objectForKey:operation];
    if (code != nil) {
        [_failures removeObjectForKey:operation];
        if (error != NULL) {
            *error = MIDINetworkMakeStandardError((MIDINetworkErrorCode)[code integerValue]);
        }
        return NO;
    }
    return YES;
}

- (uint32_t)nextRandom
{
    _random = _random * 1103515245u + 12345u;
    return (_random >> 16) & 0x7fff;
}

#pragma mark - Simulation

- (void)advanceSimulation
{
    if ([self status] != MIDINetworkBackendStatusRunning) {
        return;
    }
    if (!_discovered) {
        _discovered = YES;
        [self.state setDiscoveredHosts:@[
            [self discoveredHost:@"Studio Laptop" address:@"192.168.1.20"],
            [self discoveredHost:@"Rack Synth" address:@"192.168.1.31"],
            [self discoveredHost:MIDINetworkFakeRejectingHostName address:@"192.168.1.40"]
        ]];
        [self notifyDirectoryChanged];
    }

    /* Latency first, so a participant accepted in this step starts with
       its initial value. */
    for (MIDINetworkSession *session in [self.state sessions]) {
        BOOL changed = NO;
        for (MIDINetworkParticipant *p in [self.state participantsForSessionWithIdentifier:session.identifier]) {
            if (![p isConnected]) {
                continue;
            }
            double delta = ((double)([self nextRandom] % 21) - 10.0) / 10.0;
            p.latency = MAX(1.0, MIN(20.0, p.latency + delta));
            changed = [self.state replaceParticipant:p inSession:session.identifier] || changed;
        }
        if (changed) {
            [self notifyParticipantsChangedForSession:session.identifier];
        }
    }

    NSArray *pending = [_invitations copy];
    [_invitations removeAllObjects];
    for (MIDINetworkFakeInvitation *invitation in pending) {
        [self answerInvitation:invitation];
    }
}

- (MIDINetworkHost *)discoveredHost:(NSString *)name address:(NSString *)address
{
    MIDINetworkHost *host = [MIDINetworkHost manualHostWithName:name address:address
                                                           port:MIDINETWORK_DEFAULT_PORT];
    /* Stable identifiers, as a browser keyed by service name would have. */
    host.identifier = [@"fake:" stringByAppendingString:name];
    host.source = MIDINetworkHostSourceDiscovered;
    return host;
}

- (void)answerInvitation:(MIDINetworkFakeInvitation *)invitation
{
    NSString *sessionIdentifier = invitation.sessionIdentifier;
    MIDINetworkParticipant *participant = nil;
    for (MIDINetworkParticipant *p in [self.state participantsForSessionWithIdentifier:sessionIdentifier]) {
        if ([p.identifier isEqual:invitation.participantIdentifier]) {
            participant = p;
        }
    }
    if (participant == nil) {
        return;     /* disconnected or session disabled in the meantime */
    }
    if (invitation.rejects) {
        [self.state removeParticipantWithIdentifier:participant.identifier fromSession:sessionIdentifier error:NULL];
        [self notifyParticipantsChangedForSession:sessionIdentifier];
        [self notifyError:MIDINetworkMakeStandardError(MIDINetworkErrorPeerRejected)];
        return;
    }
    participant.state = MIDINetworkParticipantStateConnected;
    participant.latency = 2.0 + (double)([self nextRandom] % 40) / 10.0;
    [self.state replaceParticipant:participant inSession:sessionIdentifier];
    [self notifyParticipantsChangedForSession:sessionIdentifier];
}

- (void)simulateParticipant:(NSString *)participantIdentifier leavingSession:(NSString *)sessionIdentifier
{
    if ([self.state removeParticipantWithIdentifier:participantIdentifier fromSession:sessionIdentifier
                                              error:NULL]) {
        [self notifyParticipantsChangedForSession:sessionIdentifier];
    }
}

#pragma mark - Changes

- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationAddSession error:error]
        || ![self.state addSession:session error:error]) {
        return NO;
    }
    [self notifySessionsChanged];
    return YES;
}

- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationRemoveSession error:error]
        || ![self.state removeSessionWithIdentifier:identifier error:error]) {
        return NO;
    }
    [self notifySessionsChanged];
    [self notifyParticipantsChangedForSession:identifier];
    [self notifyRoutesChanged];
    return YES;
}

- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationUpdateSession error:error]
        || ![self.state updateSession:session error:error]) {
        return NO;
    }
    [self notifySessionsChanged];
    return YES;
}

- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    BOOL hadParticipants = [[self.state participantsForSessionWithIdentifier:identifier] count] > 0;
    if (![self mayPerform:MIDINetworkFakeOperationSetEnabled error:error]
        || ![self.state setEnabled:enabled forSessionWithIdentifier:identifier error:error]) {
        return NO;
    }
    [self notifySessionsChanged];
    if (!enabled && hadParticipants) {
        [self notifyParticipantsChangedForSession:identifier];
    }
    return YES;
}

- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationAddManualHost error:error]
        || ![self.state addManualHost:host error:error]) {
        return NO;
    }
    [self notifyDirectoryChanged];
    return YES;
}

- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationRemoveHost error:error]
        || ![self.state removeHostWithIdentifier:identifier error:error]) {
        return NO;
    }
    [self notifyDirectoryChanged];
    return YES;
}

- (BOOL)connectSessionWithIdentifier:(NSString *)sessionIdentifier
                toHostWithIdentifier:(NSString *)hostIdentifier error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationConnect error:error]
        || ![self.state validateConnectSession:sessionIdentifier toHost:hostIdentifier error:error]) {
        return NO;
    }
    MIDINetworkHost *host = [self.state hostWithIdentifier:hostIdentifier];
    MIDINetworkParticipant *participant = [[MIDINetworkParticipant alloc] init];
    participant.identifier = [NSString stringWithFormat:@"%@@%@:%lu", host.name, host.address,
                              (unsigned long)host.port];
    participant.name = host.name;
    participant.address = [NSString stringWithFormat:@"%@:%lu", host.address, (unsigned long)host.port];
    participant.latency = -1.0;
    participant.state = MIDINetworkParticipantStateInviting;
    if (![self.state addParticipant:participant toSession:sessionIdentifier error:error]) {
        return NO;
    }
    MIDINetworkFakeInvitation *invitation = [[MIDINetworkFakeInvitation alloc] init];
    invitation.sessionIdentifier = sessionIdentifier;
    invitation.participantIdentifier = participant.identifier;
    invitation.rejects = [host.name isEqualToString:MIDINetworkFakeRejectingHostName];
    [_invitations addObject:invitation];
    [self notifyParticipantsChangedForSession:sessionIdentifier];
    return YES;
}

- (BOOL)disconnectParticipantWithIdentifier:(NSString *)participantIdentifier
                  fromSessionWithIdentifier:(NSString *)sessionIdentifier error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationDisconnect error:error]
        || ![self.state removeParticipantWithIdentifier:participantIdentifier fromSession:sessionIdentifier
                                                  error:error]) {
        return NO;
    }
    [self notifyParticipantsChangedForSession:sessionIdentifier];
    return YES;
}

- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error
{
    if (![self mayPerform:MIDINetworkFakeOperationSetRoute error:error]
        || ![self.state setRoute:route error:error]) {
        return NO;
    }
    [self notifyRoutesChanged];
    return YES;
}

@end
