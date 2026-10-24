/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkState.h"
#import "MIDINetworkBackend.h"

NSString * const MIDINetworkStateKeySessions = @"sessions";
NSString * const MIDINetworkStateKeyDirectory = @"directory";
NSString * const MIDINetworkStateKeyParticipants = @"participants";
NSString * const MIDINetworkStateKeyRoutes = @"routes";
NSString * const MIDINetworkStateKeyLocalPorts = @"localPorts";

/* Error texts are fixed strings without inserted values, so a client can
   translate them by looking them up in its own strings table. */
static BOOL Fail(NSError **error, MIDINetworkErrorCode code, NSString *text)
{
    if (error != NULL) {
        *error = MIDINetworkMakeError(code, text);
    }
    return NO;
}

static NSInteger IndexOfIdentifier(NSArray *models, NSString *identifier)
{
    NSUInteger i, n = [models count];
    for (i = 0; i < n; i++) {
        if ([[[models objectAtIndex:i] identifier] isEqual:identifier]) {
            return (NSInteger)i;
        }
    }
    return -1;
}

static NSString *TrimmedString(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@implementation MIDINetworkState
{
    NSMutableArray *_sessions;
    NSMutableArray *_discovered;
    NSMutableArray *_manual;
    NSMutableDictionary *_participants;   /* session identifier -> NSMutableArray */
    NSMutableDictionary *_routes;         /* session identifier -> MIDINetworkRoute */
    NSArray *_localPorts;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _sessions = [NSMutableArray array];
        _discovered = [NSMutableArray array];
        _manual = [NSMutableArray array];
        _participants = [NSMutableDictionary dictionary];
        _routes = [NSMutableDictionary dictionary];
        _localPorts = @[];
    }
    return self;
}

+ (instancetype)stateWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *sessions = MIDINetworkModelsFromPropertyLists([plist objectForKey:MIDINetworkStateKeySessions],
                                                           [MIDINetworkSession class]);
    NSArray *hosts = MIDINetworkModelsFromPropertyLists([plist objectForKey:MIDINetworkStateKeyDirectory],
                                                        [MIDINetworkHost class]);
    NSArray *routes = MIDINetworkModelsFromPropertyLists([plist objectForKey:MIDINetworkStateKeyRoutes],
                                                         [MIDINetworkRoute class]);
    NSArray *ports = MIDINetworkModelsFromPropertyLists([plist objectForKey:MIDINetworkStateKeyLocalPorts],
                                                        [MIDINetworkPort class]);
    id participants = [plist objectForKey:MIDINetworkStateKeyParticipants];
    if (sessions == nil || hosts == nil || routes == nil || ports == nil
        || ![participants isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    MIDINetworkState *state = [[self alloc] init];
    [state->_sessions addObjectsFromArray:sessions];
    for (MIDINetworkHost *host in hosts) {
        [([host isManual] ? state->_manual : state->_discovered) addObject:host];
    }
    state->_localPorts = [ports copy];
    for (MIDINetworkRoute *route in routes) {
        [state->_routes setObject:route forKey:route.sessionIdentifier];
    }
    for (NSString *sessionIdentifier in participants) {
        NSArray *list = MIDINetworkModelsFromPropertyLists([participants objectForKey:sessionIdentifier],
                                                           [MIDINetworkParticipant class]);
        if (list == nil || ![sessionIdentifier isKindOfClass:[NSString class]]) {
            return nil;
        }
        [state->_participants setObject:[list mutableCopy] forKey:sessionIdentifier];
    }
    return state;
}

- (NSDictionary *)propertyList
{
    NSMutableDictionary *participants = [NSMutableDictionary dictionary];
    for (NSString *sessionIdentifier in _participants) {
        [participants setObject:MIDINetworkPropertyListsFromModels([_participants objectForKey:sessionIdentifier])
                         forKey:sessionIdentifier];
    }
    NSMutableArray *routes = [NSMutableArray array];
    for (MIDINetworkSession *session in _sessions) {
        MIDINetworkRoute *route = [_routes objectForKey:session.identifier];
        if (route != nil) {
            [routes addObject:[route propertyList]];
        }
    }
    return @{ MIDINetworkStateKeySessions: MIDINetworkPropertyListsFromModels(_sessions),
              MIDINetworkStateKeyDirectory: MIDINetworkPropertyListsFromModels([self directory]),
              MIDINetworkStateKeyParticipants: participants,
              MIDINetworkStateKeyRoutes: routes,
              MIDINetworkStateKeyLocalPorts: MIDINetworkPropertyListsFromModels(_localPorts) };
}

#pragma mark - Reads

/* Reads hand out copies, so a client editing a model it got here cannot
   change the state behind the validation. */
static NSArray *CopiedModels(NSArray *models)
{
    return [[NSArray alloc] initWithArray:models copyItems:YES];
}

- (NSArray *)sessions
{
    return CopiedModels(_sessions);
}

- (MIDINetworkSession *)sessionWithIdentifier:(NSString *)identifier
{
    NSInteger i = IndexOfIdentifier(_sessions, identifier);
    return i < 0 ? nil : [[_sessions objectAtIndex:i] copy];
}

- (NSArray *)directory
{
    NSSortDescriptor *byName = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES
                                                              selector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *all = [[_discovered sortedArrayUsingDescriptors:@[byName]] mutableCopy];
    [all addObjectsFromArray:[_manual sortedArrayUsingDescriptors:@[byName]]];
    return CopiedModels(all);
}

- (MIDINetworkHost *)hostWithIdentifier:(NSString *)identifier
{
    NSInteger i = IndexOfIdentifier(_discovered, identifier);
    if (i >= 0) {
        return [[_discovered objectAtIndex:i] copy];
    }
    i = IndexOfIdentifier(_manual, identifier);
    return i < 0 ? nil : [[_manual objectAtIndex:i] copy];
}

- (NSArray *)participantsForSessionWithIdentifier:(NSString *)identifier
{
    NSArray *list = identifier ? [_participants objectForKey:identifier] : nil;
    return list ? CopiedModels(list) : @[];
}

- (NSArray *)localPorts
{
    return CopiedModels(_localPorts);
}

- (MIDINetworkPort *)localPortWithIdentifier:(NSString *)identifier
{
    NSInteger i = IndexOfIdentifier(_localPorts, identifier);
    return i < 0 ? nil : [[_localPorts objectAtIndex:i] copy];
}

- (MIDINetworkRoute *)routeForSessionWithIdentifier:(NSString *)identifier
{
    if (IndexOfIdentifier(_sessions, identifier) < 0) {
        return nil;
    }
    MIDINetworkRoute *route = [_routes objectForKey:identifier];
    return route ? [route copy] : [MIDINetworkRoute routeForSession:identifier inputPort:nil outputPort:nil];
}

- (NSUInteger)unusedPort
{
    NSUInteger port;
    /* Even ports only: each session occupies port and port + 1. */
    for (port = MIDINETWORK_DEFAULT_PORT; port <= MIDINETWORK_MAX_PORT; port += 2) {
        if (![self portRangeOfPort:port isUsedExcept:nil]) {
            return port;
        }
    }
    return 0;
}

- (NSString *)unusedSessionNameWithBase:(NSString *)base
{
    NSString *candidate = base;
    NSUInteger n = 2;
    while ([self sessionNamed:candidate except:nil] != nil) {
        candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n++];
    }
    return candidate;
}

- (MIDINetworkSession *)proposedSession
{
    return [MIDINetworkSession sessionWithName:[self unusedSessionNameWithBase:MIDINetworkMachineName()]
                                          port:[self unusedPort]];
}

#pragma mark - Validation

- (MIDINetworkSession *)sessionNamed:(NSString *)name except:(NSString *)identifier
{
    for (MIDINetworkSession *s in _sessions) {
        if (![s.identifier isEqual:identifier] && [s.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return s;
        }
    }
    return nil;
}

- (BOOL)portRangeOfPort:(NSUInteger)port isUsedExcept:(NSString *)identifier
{
    for (MIDINetworkSession *s in _sessions) {
        if (![s.identifier isEqual:identifier] && s.port + 1 >= port && port + 1 >= s.port) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)validateSession:(MIDINetworkSession *)session isNew:(BOOL)isNew error:(NSError **)error
{
    if (session == nil || [session.identifier length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session is missing an identifier.");
    }
    if (isNew && IndexOfIdentifier(_sessions, session.identifier) >= 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"A session with this identifier already exists.");
    }
    if (!isNew && IndexOfIdentifier(_sessions, session.identifier) < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    if ([TrimmedString(session.name) length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session needs a local name.");
    }
    if ([TrimmedString(session.advertisedName) length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session needs an advertised name.");
    }
    if ([self sessionNamed:session.name except:session.identifier] != nil) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"Another session already has this local name.");
    }
    if (session.port < MIDINETWORK_MIN_PORT || session.port > MIDINETWORK_MAX_PORT) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The port must be between 1024 and 65534.");
    }
    if ([self portRangeOfPort:session.port isUsedExcept:session.identifier]) {
        return Fail(error, MIDINetworkErrorPortInUse,
                    @"Another session already uses this port or the one above it.");
    }
    if (MIDINetworkConnectionPolicyName(session.policy) == nil) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The connection policy is not known.");
    }
    return YES;
}

#pragma mark - Session mutators

- (BOOL)addSession:(MIDINetworkSession *)session error:(NSError **)error
{
    if (![self validateSession:session isNew:YES error:error]) {
        return NO;
    }
    [_sessions addObject:[session copy]];
    return YES;
}

- (BOOL)removeSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    NSInteger i = IndexOfIdentifier(_sessions, identifier);
    if (i < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    [_sessions removeObjectAtIndex:i];
    [_participants removeObjectForKey:identifier];
    [_routes removeObjectForKey:identifier];
    return YES;
}

- (BOOL)updateSession:(MIDINetworkSession *)session error:(NSError **)error
{
    if (![self validateSession:session isNew:NO error:error]) {
        return NO;
    }
    NSInteger i = IndexOfIdentifier(_sessions, session.identifier);
    MIDINetworkSession *updated = [session copy];
    updated.enabled = [[_sessions objectAtIndex:i] isEnabled];
    [_sessions replaceObjectAtIndex:i withObject:updated];
    return YES;
}

- (BOOL)setEnabled:(BOOL)enabled forSessionWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    NSInteger i = IndexOfIdentifier(_sessions, identifier);
    if (i < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    MIDINetworkSession *updated = [[_sessions objectAtIndex:i] copy];
    updated.enabled = enabled;
    [_sessions replaceObjectAtIndex:i withObject:updated];
    if (!enabled) {
        [_participants removeObjectForKey:identifier];
    }
    return YES;
}

#pragma mark - Directory mutators

- (BOOL)addManualHost:(MIDINetworkHost *)host error:(NSError **)error
{
    if (host == nil || [host.identifier length] == 0 || [self hostWithIdentifier:host.identifier] != nil) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The host is missing an identifier.");
    }
    if ([TrimmedString(host.name) length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The host needs a name.");
    }
    if ([TrimmedString(host.address) length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The host needs an address.");
    }
    if (host.port < 1 || host.port > MIDINETWORK_MAX_PORT) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The port must be between 1 and 65534.");
    }
    MIDINetworkHost *stored = [host copy];
    stored.source = MIDINetworkHostSourceManual;
    [_manual addObject:stored];
    return YES;
}

- (BOOL)removeHostWithIdentifier:(NSString *)identifier error:(NSError **)error
{
    NSInteger i = IndexOfIdentifier(_manual, identifier);
    if (i < 0) {
        if (IndexOfIdentifier(_discovered, identifier) >= 0) {
            return Fail(error, MIDINetworkErrorInvalidArgument,
                        @"Hosts found on the network cannot be removed from the directory.");
        }
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The host does not exist.");
    }
    [_manual removeObjectAtIndex:i];
    return YES;
}

- (void)setDiscoveredHosts:(NSArray *)hosts
{
    [_discovered removeAllObjects];
    for (MIDINetworkHost *host in hosts) {
        MIDINetworkHost *stored = [host copy];
        stored.source = MIDINetworkHostSourceDiscovered;
        [_discovered addObject:stored];
    }
}

#pragma mark - Participants

- (BOOL)validateConnectSession:(NSString *)sessionIdentifier
                        toHost:(NSString *)hostIdentifier error:(NSError **)error
{
    NSInteger i = IndexOfIdentifier(_sessions, sessionIdentifier);
    if (i < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    if (![[_sessions objectAtIndex:i] isEnabled]) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"Turn the session on before connecting.");
    }
    if ([self hostWithIdentifier:hostIdentifier] == nil) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The host does not exist.");
    }
    return YES;
}

- (BOOL)addParticipant:(MIDINetworkParticipant *)participant
             toSession:(NSString *)sessionIdentifier error:(NSError **)error
{
    NSInteger i = IndexOfIdentifier(_sessions, sessionIdentifier);
    if (i < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    if (![[_sessions objectAtIndex:i] isEnabled]) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"Turn the session on before connecting.");
    }
    if ([participant.identifier length] == 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The participant is missing an identifier.");
    }
    NSMutableArray *list = [_participants objectForKey:sessionIdentifier];
    if (list == nil) {
        list = [NSMutableArray array];
        [_participants setObject:list forKey:sessionIdentifier];
    }
    if (IndexOfIdentifier(list, participant.identifier) >= 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The participant is already in the session.");
    }
    [list addObject:[participant copy]];
    return YES;
}

- (BOOL)removeParticipantWithIdentifier:(NSString *)participantIdentifier
                            fromSession:(NSString *)sessionIdentifier error:(NSError **)error
{
    NSMutableArray *list = sessionIdentifier ? [_participants objectForKey:sessionIdentifier] : nil;
    NSInteger i = list ? IndexOfIdentifier(list, participantIdentifier) : -1;
    if (i < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The participant is not in the session.");
    }
    [list removeObjectAtIndex:i];
    return YES;
}

- (BOOL)replaceParticipant:(MIDINetworkParticipant *)participant inSession:(NSString *)sessionIdentifier
{
    NSMutableArray *list = sessionIdentifier ? [_participants objectForKey:sessionIdentifier] : nil;
    NSInteger i = list ? IndexOfIdentifier(list, participant.identifier) : -1;
    if (i < 0) {
        return NO;
    }
    [list replaceObjectAtIndex:i withObject:[participant copy]];
    return YES;
}

#pragma mark - Routing

- (void)setLocalPorts:(NSArray *)ports
{
    _localPorts = CopiedModels(ports);
    for (NSString *sessionIdentifier in [_routes allKeys]) {
        MIDINetworkRoute *route = [[_routes objectForKey:sessionIdentifier] copy];
        if (route.inputPortIdentifier && IndexOfIdentifier(_localPorts, route.inputPortIdentifier) < 0) {
            route.inputPortIdentifier = nil;
        }
        if (route.outputPortIdentifier && IndexOfIdentifier(_localPorts, route.outputPortIdentifier) < 0) {
            route.outputPortIdentifier = nil;
        }
        [_routes setObject:route forKey:sessionIdentifier];
    }
}

- (BOOL)setRoute:(MIDINetworkRoute *)route error:(NSError **)error
{
    if (IndexOfIdentifier(_sessions, route.sessionIdentifier) < 0) {
        return Fail(error, MIDINetworkErrorInvalidArgument, @"The session does not exist.");
    }
    if (route.inputPortIdentifier != nil) {
        NSInteger i = IndexOfIdentifier(_localPorts, route.inputPortIdentifier);
        if (i < 0 || ![[_localPorts objectAtIndex:i] canSend]) {
            return Fail(error, MIDINetworkErrorInvalidArgument, @"The MIDI port cannot send to the session.");
        }
    }
    if (route.outputPortIdentifier != nil) {
        NSInteger i = IndexOfIdentifier(_localPorts, route.outputPortIdentifier);
        if (i < 0 || ![[_localPorts objectAtIndex:i] canReceive]) {
            return Fail(error, MIDINetworkErrorInvalidArgument, @"The MIDI port cannot receive from the session.");
        }
    }
    [_routes setObject:[route copy] forKey:route.sessionIdentifier];
    return YES;
}

@end
