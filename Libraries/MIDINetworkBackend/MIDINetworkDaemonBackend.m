/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkDaemonBackend.h"

/* Short timeouts: the pane calls on the main thread, and a daemon that
   hangs must not freeze System Preferences for the DO default of minutes. */
static const NSTimeInterval kDaemonCallTimeout = 5.0;

#pragma mark - Distributed Objects connector

@implementation MIDINetworkDistributedObjectsConnector
{
    NSMutableDictionary *_observers;   /* connection pointer value -> observer token */
}

- (instancetype)init
{
    if ((self = [super init])) {
        _observers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isDaemonInstalled
{
    NSString *tools = [NSSearchPathForDirectoriesInDomains(GSToolsDirectory, NSSystemDomainMask, YES) firstObject];
    NSString *path = [tools stringByAppendingPathComponent:MIDINetworkDaemonToolName];
    return [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

- (id<MIDINetworkDaemonControl>)connect
{
    NSConnection *connection =
        [NSConnection connectionWithRegisteredName:MIDINetworkDaemonServiceName()
                                              host:nil
                                   usingNameServer:[NSMessagePortNameServer sharedInstance]];
    if (connection == nil) {
        return nil;
    }
    [connection setRequestTimeout:kDaemonCallTimeout];
    [connection setReplyTimeout:kDaemonCallTimeout];
    id proxy = [connection rootProxy];
    if (proxy == nil) {
        return nil;
    }
    [proxy setProtocolForProxy:@protocol(MIDINetworkDaemonControl)];
    return proxy;
}

- (void)watchControl:(id<MIDINetworkDaemonControl>)control lost:(void (^)(void))lostBlock
{
    NSConnection *connection = [(NSDistantObject *)control connectionForProxy];
    id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSConnectionDidDieNotification object:connection queue:nil
                usingBlock:^(NSNotification *note) { (void)note; lostBlock(); }];
    [_observers setObject:token forKey:[NSValue valueWithNonretainedObject:connection]];
}

- (void)disconnectControl:(id<MIDINetworkDaemonControl>)control
{
    NSConnection *connection = [(NSDistantObject *)control connectionForProxy];
    NSValue *key = [NSValue valueWithNonretainedObject:connection];
    id token = [_observers objectForKey:key];
    if (token != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
        [_observers removeObjectForKey:key];
    }
    [connection invalidate];
}

@end

#pragma mark - Backend

@implementation MIDINetworkDaemonBackend
{
    id<MIDINetworkDaemonConnector> _connector;
    id<MIDINetworkDaemonControl> _control;
    NSTimer *_retryTimer;
    BOOL _started;
}

- (instancetype)initWithConnector:(id<MIDINetworkDaemonConnector>)connector
{
    if ((self = [super init])) {
        _connector = connector;
        _retryInterval = 3.0;
        [self setStatus:MIDINetworkBackendStatusDaemonNotRunning
                  error:MIDINetworkMakeStandardError(MIDINetworkErrorDaemonNotRunning)];
    }
    return self;
}

- (void)dealloc
{
    [_retryTimer invalidate];
}

- (NSString *)backendName
{
    return MIDINetworkDaemonToolName;
}

- (void)start
{
    _started = YES;
    if (_control == nil) {
        [self tryConnect];
    }
}

- (void)stop
{
    _started = NO;
    [_retryTimer invalidate];
    _retryTimer = nil;
    [self dropControlNotifying:NO];
}

- (void)scheduleRetry
{
    if (_started && _retryTimer == nil && _retryInterval > 0) {
        _retryTimer = [NSTimer scheduledTimerWithTimeInterval:_retryInterval target:self
                                                     selector:@selector(retryTimerFired:)
                                                     userInfo:nil repeats:NO];
    }
}

- (void)retryTimerFired:(NSTimer *)timer
{
    _retryTimer = nil;
    [self tryConnect];
}

- (void)tryConnect
{
    id<MIDINetworkDaemonControl> control = nil;
    NSDictionary *snapshot = nil;
    @try {
        control = [_connector connect];
        if (control != nil) {
            if ([control protocolVersion] != MIDINETWORK_CONTROL_PROTOCOL_VERSION) {
                [_connector disconnectControl:control];
                /* A version mismatch will not fix itself by retrying. */
                [self setStatus:MIDINetworkBackendStatusUnavailable
                          error:MIDINetworkMakeError(MIDINetworkErrorUnavailable,
                                                     @"The network MIDI service is a different version than this program.")];
                return;
            }
            /* Register before reading the snapshot, so no change can fall
               between the two. */
            [control registerClient:self];
            snapshot = [control snapshot];
        }
    }
    @catch (NSException *exception) {
        NSDebugLLog(@"MIDINetwork", @"networkmidid connection failed: %@", exception);
        if (control != nil) {
            [_connector disconnectControl:control];
        }
        control = nil;
    }

    MIDINetworkState *state = control ? [MIDINetworkState stateWithPropertyList:snapshot] : nil;
    if (state == nil) {
        if (control != nil) {
            [_connector disconnectControl:control];
        }
        [self setStatus:MIDINetworkBackendStatusDaemonNotRunning
                  error:MIDINetworkMakeStandardError(MIDINetworkErrorDaemonNotRunning)];
        [self scheduleRetry];
        return;
    }

    _control = control;
    __weak MIDINetworkDaemonBackend *weakSelf = self;
    [_connector watchControl:control lost:^{ [weakSelf controlLost]; }];
    self.state = state;
    [self setStatus:MIDINetworkBackendStatusRunning error:nil];
    [self notifyEverythingChanged];
}

- (void)controlLost
{
    [self dropControlNotifying:YES];
    [self scheduleRetry];
}

- (void)dropControlNotifying:(BOOL)notify
{
    if (_control == nil) {
        return;
    }
    id<MIDINetworkDaemonControl> control = _control;
    _control = nil;
    if (!notify) {
        @try {
            [control unregisterClient:self];
        }
        @catch (NSException *exception) {
            NSDebugLLog(@"MIDINetwork", @"networkmidid unregister failed: %@", exception);
        }
    }
    [_connector disconnectControl:control];
    /* Showing the last known sessions as if they were live would lie. */
    self.state = [[MIDINetworkState alloc] init];
    [self setStatus:MIDINetworkBackendStatusDaemonNotRunning
              error:MIDINetworkMakeStandardError(MIDINetworkErrorDaemonNotRunning)];
    if (notify) {
        [self notifyEverythingChanged];
    }
}

- (void)notifyEverythingChanged
{
    [self notifySessionsChanged];
    [self notifyDirectoryChanged];
    [self notifyParticipantsChangedForSession:nil];
    [self notifyRoutesChanged];
    [self notifyLocalPortsChanged];
}

#pragma mark - Applying changes

/* Each section present replaces that section; the result is validated
   as a whole like a snapshot, so a malformed push cannot corrupt state. */
- (void)applyChanges:(NSDictionary *)changes
{
    if (![changes isKindOfClass:[NSDictionary class]] || [changes count] == 0) {
        return;
    }
    NSMutableDictionary *merged = [[self.state propertyList] mutableCopy];
    [merged addEntriesFromDictionary:changes];
    MIDINetworkState *state = [MIDINetworkState stateWithPropertyList:merged];
    if (state == nil) {
        NSDebugLLog(@"MIDINetwork", @"networkmidid sent malformed changes: %@", changes);
        [self notifyError:MIDINetworkMakeError(MIDINetworkErrorInvalidArgument,
                                               @"The network MIDI service sent an answer that is not understood.")];
        return;
    }
    self.state = state;
    if ([changes objectForKey:MIDINetworkStateKeySessions]) {
        [self notifySessionsChanged];
    }
    if ([changes objectForKey:MIDINetworkStateKeyDirectory]) {
        [self notifyDirectoryChanged];
    }
    if ([changes objectForKey:MIDINetworkStateKeyParticipants]) {
        [self notifyParticipantsChangedForSession:nil];
    }
    if ([changes objectForKey:MIDINetworkStateKeyRoutes]) {
        [self notifyRoutesChanged];
    }
    if ([changes objectForKey:MIDINetworkStateKeyLocalPorts]) {
        [self notifyLocalPortsChanged];
    }
}

- (oneway void)daemonDidChange:(bycopy NSDictionary *)changes
{
    [self applyChanges:changes];
}

- (oneway void)daemonDidEncounterError:(bycopy NSDictionary *)error
{
    NSError *e = MIDINetworkErrorFromReply(@{ MIDINetworkReplyKeyError: error ?: @{} });
    [self notifyError:e];
}

/* Runs one control call; maps exceptions (timeouts, a dead connection) to
   errors and applies the changes a successful reply carries. */
- (BOOL)call:(NSDictionary *(^)(id<MIDINetworkDaemonControl> control))block error:(NSError **)error
{
    if (_control == nil) {
        return [self refuse:error];
    }
    NSDictionary *reply = nil;
    @try {
        reply = block(_control);
    }
    @catch (NSException *exception) {
        BOOL timeout = [[exception name] isEqual:NSPortTimeoutException];
        [self controlLost];
        if (error != NULL) {
            *error = MIDINetworkMakeStandardError(timeout ? MIDINetworkErrorTimeout
                                                          : MIDINetworkErrorDaemonNotRunning);
        }
        return NO;
    }
    NSError *replyError = MIDINetworkErrorFromReply(reply);
    if (replyError != nil) {
        if (error != NULL) {
            *error = replyError;
        }
        return NO;
    }
    [self applyChanges:[reply objectForKey:MIDINetworkReplyKeyChanges]];
    return YES;
}

#pragma mark - Changes

- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error
{
    NSDictionary *plist = [session propertyList];
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c addSession:plist]; } error:error];
}

- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c removeSession:identifier]; } error:error];
}

- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error
{
    NSDictionary *plist = [session propertyList];
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c updateSession:plist]; } error:error];
}

- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c setEnabled:enabled forSession:identifier]; }
                error:error];
}

- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error
{
    NSDictionary *plist = [host propertyList];
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c addManualHost:plist]; } error:error];
}

- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c removeHost:identifier]; } error:error];
}

- (BOOL)connectSessionWithIdentifier:(NSString *)sessionIdentifier
                toHostWithIdentifier:(NSString *)hostIdentifier error:(NSError **)error
{
    return [self call:^(id<MIDINetworkDaemonControl> c) {
        return [c connectSession:sessionIdentifier toHost:hostIdentifier];
    } error:error];
}

- (BOOL)disconnectParticipantWithIdentifier:(NSString *)participantIdentifier
                  fromSessionWithIdentifier:(NSString *)sessionIdentifier error:(NSError **)error
{
    return [self call:^(id<MIDINetworkDaemonControl> c) {
        return [c disconnectParticipant:participantIdentifier fromSession:sessionIdentifier];
    } error:error];
}

- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error
{
    NSDictionary *plist = [route propertyList];
    return [self call:^(id<MIDINetworkDaemonControl> c) { return [c setRoute:plist]; } error:error];
}

@end
