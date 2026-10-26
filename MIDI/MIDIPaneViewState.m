/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDIPaneViewState.h"
#import "MIDINetworkState.h"
#import "MIDINetworkBackendFactory.h"

NSString *MIDIPaneLocalized(NSString *key)
{
    return NSLocalizedStringFromTableInBundle(key, nil, [NSBundle bundleForClass:[MIDIPaneViewState class]], nil);
}

@implementation MIDIPaneSelection

- (id)copyWithZone:(NSZone *)zone
{
    MIDIPaneSelection *s = [[MIDIPaneSelection alloc] init];
    s.sessionIdentifier = self.sessionIdentifier;
    s.hostIdentifier = self.hostIdentifier;
    s.participantIdentifier = self.participantIdentifier;
    return s;
}

@end

@implementation MIDIPaneRow
@end

static MIDIPaneRow *Row(NSString *identifier, NSString *title, NSString *detail, BOOL checked)
{
    MIDIPaneRow *row = [[MIDIPaneRow alloc] init];
    row.identifier = identifier;
    row.title = title;
    row.detail = detail ?: @"";
    row.checked = checked;
    return row;
}

static NSInteger RowIndex(NSArray *rows, NSString *identifier)
{
    NSUInteger i, n = [rows count];
    for (i = 0; identifier != nil && i < n; i++) {
        if ([[[rows objectAtIndex:i] identifier] isEqual:identifier]) {
            return (NSInteger)i;
        }
    }
    return -1;
}

/* Index of a port in a pop-up's identifiers; "None" (0) when unrouted or
   when the routed port is no longer offered. */
static NSInteger PopUpIndex(NSArray *identifiers, NSString *portIdentifier)
{
    NSUInteger i = portIdentifier ? [identifiers indexOfObject:portIdentifier] : NSNotFound;
    return i == NSNotFound ? 0 : (NSInteger)i;
}

@implementation MIDIPaneViewState

+ (instancetype)viewStateWithBackend:(id<MIDINetworkBackend>)backend
                           selection:(MIDIPaneSelection *)selection
                           lastError:(NSError *)lastError
{
    MIDIPaneViewState *v = [[self alloc] init];
    [v buildWithBackend:backend selection:selection ?: [[MIDIPaneSelection alloc] init] lastError:lastError];
    return v;
}

- (void)buildWithBackend:(id<MIDINetworkBackend>)backend
               selection:(MIDIPaneSelection *)requested
               lastError:(NSError *)lastError
{
    BOOL running = [backend status] == MIDINetworkBackendStatusRunning;
    _selection = [requested copy];

    /* Sessions */
    NSMutableArray *rows = [NSMutableArray array];
    for (MIDINetworkSession *s in [backend sessions]) {
        [rows addObject:Row(s.identifier, s.name, nil, s.enabled)];
    }
    _sessionRows = rows;
    _selectedSessionRow = RowIndex(rows, _selection.sessionIdentifier);
    if (_selectedSessionRow < 0 && [rows count] > 0) {
        _selectedSessionRow = 0;
    }
    _selection.sessionIdentifier = _selectedSessionRow < 0 ? nil
        : [[rows objectAtIndex:_selectedSessionRow] identifier];
    MIDINetworkSession *session = [backend sessionWithIdentifier:_selection.sessionIdentifier];

    _canAddSession = running;
    _canRemoveSession = running && session != nil;
    _detailsEnabled = running && session != nil;
    _localName = session.name ?: @"";
    _advertisedName = session.advertisedName ?: @"";
    _portText = session ? [NSString stringWithFormat:@"%lu", (unsigned long)session.port] : @"";
    _policyTitles = @[ MIDIPaneLocalized(@"Anyone"),
                       MIDIPaneLocalized(@"Only computers in my directory"),
                       MIDIPaneLocalized(@"No one") ];
    _policyIndex = session ? session.policy : MIDINetworkConnectionPolicyAnyone;

    /* Directory */
    rows = [NSMutableArray array];
    MIDINetworkHost *host = nil;
    for (MIDINetworkHost *h in [backend directory]) {
        [rows addObject:Row(h.identifier, h.name, h.address, NO)];
        if ([h.identifier isEqual:_selection.hostIdentifier]) {
            host = h;
        }
    }
    _directoryRows = rows;
    _selectedHostRow = RowIndex(rows, _selection.hostIdentifier);
    if (host == nil) {
        _selection.hostIdentifier = nil;
    }
    _canAddHost = running;
    _canRemoveHost = running && [host isManual];
    _canConnect = running && host != nil && session.enabled;

    /* Participants of the selected session */
    rows = [NSMutableArray array];
    for (MIDINetworkParticipant *p in [backend participantsForSessionWithIdentifier:session.identifier]) {
        NSString *detail;
        if (![p isConnected]) {
            detail = MIDIPaneLocalized(@"Connecting...");
        } else if (p.latency < 0) {
            detail = @"-";
        } else {
            detail = [NSString stringWithFormat:MIDIPaneLocalized(@"%.0f ms"), p.latency];
        }
        [rows addObject:Row(p.identifier, p.name, detail, NO)];
    }
    _participantRows = rows;
    _selectedParticipantRow = RowIndex(rows, _selection.participantIdentifier);
    if (_selectedParticipantRow < 0) {
        _selection.participantIdentifier = nil;
    }
    _canDisconnect = running && _selectedParticipantRow >= 0;

    /* Routing */
    MIDINetworkRoute *route = session ? [backend routeForSessionWithIdentifier:session.identifier] : nil;
    NSMutableArray *inTitles = [NSMutableArray arrayWithObject:MIDIPaneLocalized(@"None")];
    NSMutableArray *inIds = [NSMutableArray arrayWithObject:[NSNull null]];
    NSMutableArray *outTitles = [NSMutableArray arrayWithObject:MIDIPaneLocalized(@"None")];
    NSMutableArray *outIds = [NSMutableArray arrayWithObject:[NSNull null]];
    NSArray *ports = [backend localPorts];
    NSCountedSet *names = [NSCountedSet setWithArray:[ports valueForKey:@"name"]];
    for (MIDINetworkPort *port in ports) {
        /* Two ports with one name (two identical USB interfaces) could not
           be told apart, and a pop-up keeps only one item per title. */
        NSString *title = [names countForObject:port.name] > 1
            ? [NSString stringWithFormat:@"%@ (%@)", port.name, port.identifier] : port.name;
        if (port.canSend) {
            [inTitles addObject:title];
            [inIds addObject:port.identifier];
        }
        if (port.canReceive) {
            [outTitles addObject:title];
            [outIds addObject:port.identifier];
        }
    }
    _inputPortTitles = inTitles;
    _inputPortIdentifiers = inIds;
    _outputPortTitles = outTitles;
    _outputPortIdentifiers = outIds;
    _inputPortIndex = PopUpIndex(inIds, route.inputPortIdentifier);
    _outputPortIndex = PopUpIndex(outIds, route.outputPortIdentifier);
    _routingEnabled = running && session != nil;

    /* Status: the newest problem wins over the steady state. */
    if (!running) {
        NSError *reason = [backend statusError];
        MIDINetworkMIDISystem *midi = [[reason userInfo] objectForKey:MIDINetworkMIDISystemErrorKey];
        if ([midi isKindOfClass:[MIDINetworkMIDISystem class]]) {
            /* The sentence carries the device path, so it is translated as
               a format and not looked up whole. */
            _statusText = [midi descriptionWithTranslator:^(NSString *format) { return MIDIPaneLocalized(format); }];
        } else {
            _statusText = MIDIPaneLocalized([reason localizedDescription]
                                            ?: @"Network MIDI is not available on this computer.");
        }
        _statusIsError = YES;
    } else if (lastError != nil) {
        _statusText = MIDIPaneLocalized([lastError localizedDescription]);
        _statusIsError = YES;
    } else if ([[backend backendName] isEqual:MIDINetworkBackendNameSimulation]) {
        _statusText = MIDIPaneLocalized(@"Simulated network MIDI service (for development).");
        _statusIsError = NO;
    } else {
        _statusText = MIDIPaneLocalized(@"Network MIDI service is running.");
        _statusIsError = NO;
    }
}

+ (MIDINetworkSession *)proposedSessionForBackend:(id<MIDINetworkBackend>)backend
{
    /* Reuse the state's own rules for free names and ports instead of a
       second copy of them here. */
    MIDINetworkState *scratch = [[MIDINetworkState alloc] init];
    for (MIDINetworkSession *s in [backend sessions]) {
        [scratch addSession:s error:NULL];
    }
    /* Named after the machine, so peers joining it see which computer
       it is. */
    return [scratch proposedSession];
}

@end
