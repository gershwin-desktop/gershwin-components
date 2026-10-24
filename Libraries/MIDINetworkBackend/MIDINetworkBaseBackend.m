/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkBaseBackend.h"

NSString * const MIDINetworkErrorDomain = @"io.github.gershwin-desktop.MIDINetwork";

NSError *MIDINetworkMakeError(MIDINetworkErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:MIDINetworkErrorDomain code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description ?: @"" }];
}

NSError *MIDINetworkMakeStandardError(MIDINetworkErrorCode code)
{
    NSString *text;
    switch (code) {
    case MIDINetworkErrorUnavailable:
        text = @"Network MIDI is not available on this computer.";
        break;
    case MIDINetworkErrorDaemonNotRunning:
        text = @"The network MIDI service is not running.";
        break;
    case MIDINetworkErrorPortInUse:
        text = @"Another session already uses this port or the one above it.";
        break;
    case MIDINetworkErrorPeerRejected:
        text = @"The other computer declined the invitation.";
        break;
    case MIDINetworkErrorTimeout:
        text = @"The network MIDI service did not answer in time.";
        break;
    default:
        text = @"The request was not valid.";
        break;
    }
    return MIDINetworkMakeError(code, text);
}

@implementation MIDINetworkBaseBackend
{
    MIDINetworkBackendStatus _status;
    NSError *_statusError;
    __weak id<MIDINetworkBackendDelegate> _delegate;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _state = [[MIDINetworkState alloc] init];
        _status = MIDINetworkBackendStatusUnavailable;
    }
    return self;
}

- (NSString *)backendName
{
    return @"none";
}

- (MIDINetworkBackendStatus)status
{
    return _status;
}

- (NSError *)statusError
{
    return _status == MIDINetworkBackendStatusRunning ? nil : _statusError;
}

- (void)setStatus:(MIDINetworkBackendStatus)status error:(NSError *)error
{
    BOOL changed = (status != _status) || !((error == _statusError) || [error isEqual:_statusError]);
    _status = status;
    _statusError = error;
    if (changed && [_delegate respondsToSelector:@selector(midiNetworkBackendStatusDidChange:)]) {
        [_delegate midiNetworkBackendStatusDidChange:self];
    }
}

- (id<MIDINetworkBackendDelegate>)delegate
{
    return _delegate;
}

- (void)setDelegate:(id<MIDINetworkBackendDelegate>)delegate
{
    _delegate = delegate;
}

- (void)start
{
}

- (void)stop
{
}

- (BOOL)refuse:(NSError **)error
{
    if (error != NULL) {
        *error = _statusError ?: MIDINetworkMakeStandardError(MIDINetworkErrorUnavailable);
    }
    return NO;
}

#pragma mark - Reads

- (NSArray *)sessions { return [_state sessions]; }
- (MIDINetworkSession *)sessionWithIdentifier:(NSString *)identifier { return [_state sessionWithIdentifier:identifier]; }
- (NSArray *)directory { return [_state directory]; }
- (NSArray *)participantsForSessionWithIdentifier:(NSString *)identifier
{
    return [_state participantsForSessionWithIdentifier:identifier];
}
- (NSArray *)localPorts { return [_state localPorts]; }
- (MIDINetworkRoute *)routeForSessionWithIdentifier:(NSString *)identifier
{
    return [_state routeForSessionWithIdentifier:identifier];
}

#pragma mark - Changes (refused here)

- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error { return [self refuse:error]; }
- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error { return [self refuse:error]; }
- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error { return [self refuse:error]; }
- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    return [self refuse:error];
}
- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error { return [self refuse:error]; }
- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error { return [self refuse:error]; }
- (BOOL)connectSessionWithIdentifier:(NSString *)sessionIdentifier
                toHostWithIdentifier:(NSString *)hostIdentifier error:(NSError **)error
{
    return [self refuse:error];
}
- (BOOL)disconnectParticipantWithIdentifier:(NSString *)participantIdentifier
                  fromSessionWithIdentifier:(NSString *)sessionIdentifier error:(NSError **)error
{
    return [self refuse:error];
}
- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error { return [self refuse:error]; }

#pragma mark - Notifications

- (void)notifySessionsChanged
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackendSessionsDidChange:)]) {
        [_delegate midiNetworkBackendSessionsDidChange:self];
    }
}

- (void)notifyDirectoryChanged
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackendDirectoryDidChange:)]) {
        [_delegate midiNetworkBackendDirectoryDidChange:self];
    }
}

- (void)notifyParticipantsChangedForSession:(NSString *)sessionIdentifier
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackend:participantsDidChangeForSession:)]) {
        [_delegate midiNetworkBackend:self participantsDidChangeForSession:sessionIdentifier];
    }
}

- (void)notifyRoutesChanged
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackendRoutesDidChange:)]) {
        [_delegate midiNetworkBackendRoutesDidChange:self];
    }
}

- (void)notifyLocalPortsChanged
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackendLocalPortsDidChange:)]) {
        [_delegate midiNetworkBackendLocalPortsDidChange:self];
    }
}

- (void)notifyError:(NSError *)error
{
    if ([_delegate respondsToSelector:@selector(midiNetworkBackend:didEncounterError:)]) {
        [_delegate midiNetworkBackend:self didEncounterError:error];
    }
}

@end

@implementation MIDINetworkUnavailableBackend

- (instancetype)initWithReason:(NSError *)reason
{
    if ((self = [super init])) {
        [self setStatus:MIDINetworkBackendStatusUnavailable error:reason];
    }
    return self;
}

- (NSString *)backendName
{
    return @"unavailable";
}

@end
