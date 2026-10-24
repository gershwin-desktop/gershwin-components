/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MIDINetworkModels.h"

NSString * const MIDINetworkKeyIdentifier = @"identifier";
NSString * const MIDINetworkKeyName = @"name";
NSString * const MIDINetworkKeyAdvertisedName = @"advertisedName";
NSString * const MIDINetworkKeyPort = @"port";
NSString * const MIDINetworkKeyEnabled = @"enabled";
NSString * const MIDINetworkKeyPolicy = @"policy";
NSString * const MIDINetworkKeyAddress = @"address";
NSString * const MIDINetworkKeySource = @"source";
NSString * const MIDINetworkKeyLatency = @"latency";
NSString * const MIDINetworkKeyState = @"state";
NSString * const MIDINetworkKeySession = @"session";
NSString * const MIDINetworkKeyInputPort = @"inputPort";
NSString * const MIDINetworkKeyOutputPort = @"outputPort";
NSString * const MIDINetworkKeyCanSend = @"canSend";
NSString * const MIDINetworkKeyCanReceive = @"canReceive";

static NSString * const kPolicyNames[] = { @"anyone", @"directory", @"nobody" };
static NSString * const kSourceNames[] = { @"discovered", @"manual" };
static NSString * const kStateNames[] = { @"inviting", @"connected" };

/* Typed reads: a value of the wrong type counts as missing, so a broken
   plist is rejected as a whole rather than turned into a default. */
static NSString *PLString(NSDictionary *d, NSString *key)
{
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSNumber *PLNumber(NSDictionary *d, NSString *key)
{
    id v = [d objectForKey:key];
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

static BOOL PLIndexOfName(NSString *name, NSString * const *names, NSInteger count, NSInteger *index)
{
    NSInteger i;
    for (i = 0; i < count; i++) {
        if ([names[i] isEqualToString:name]) {
            *index = i;
            return YES;
        }
    }
    return NO;
}

static BOOL PLEqual(id a, id b)
{
    return (a == b) || [a isEqual:b];
}

NSString *MIDINetworkConnectionPolicyName(MIDINetworkConnectionPolicy policy)
{
    if (policy < MIDINetworkConnectionPolicyAnyone || policy > MIDINetworkConnectionPolicyNobody) {
        return nil;
    }
    return kPolicyNames[policy];
}

BOOL MIDINetworkConnectionPolicyFromName(NSString *name, MIDINetworkConnectionPolicy *policy)
{
    NSInteger index;
    if (![name isKindOfClass:[NSString class]] || !PLIndexOfName(name, kPolicyNames, 3, &index)) {
        return NO;
    }
    *policy = (MIDINetworkConnectionPolicy)index;
    return YES;
}

NSString *MIDINetworkMakeIdentifier(void)
{
    return [[NSProcessInfo processInfo] globallyUniqueString];
}

@protocol MIDINetworkPropertyListModel
+ (id)modelWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
@end

#pragma mark - MIDINetworkSession

@implementation MIDINetworkSession

+ (instancetype)sessionWithName:(NSString *)name port:(NSUInteger)port
{
    MIDINetworkSession *s = [[self alloc] init];
    s.identifier = MIDINetworkMakeIdentifier();
    s.name = name;
    s.advertisedName = name;
    s.port = port;
    s.enabled = NO;
    s.policy = MIDINetworkConnectionPolicyAnyone;
    return s;
}

+ (instancetype)sessionWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *identifier = PLString(plist, MIDINetworkKeyIdentifier);
    NSString *name = PLString(plist, MIDINetworkKeyName);
    NSString *advertised = PLString(plist, MIDINetworkKeyAdvertisedName);
    NSNumber *port = PLNumber(plist, MIDINetworkKeyPort);
    NSNumber *enabled = PLNumber(plist, MIDINetworkKeyEnabled);
    MIDINetworkConnectionPolicy policy;
    if (identifier == nil || name == nil || advertised == nil || port == nil || enabled == nil
        || !MIDINetworkConnectionPolicyFromName(PLString(plist, MIDINetworkKeyPolicy), &policy)) {
        return nil;
    }
    MIDINetworkSession *s = [[self alloc] init];
    s.identifier = identifier;
    s.name = name;
    s.advertisedName = advertised;
    s.port = [port unsignedIntegerValue];
    s.enabled = [enabled boolValue];
    s.policy = policy;
    return s;
}

+ (id)modelWithPropertyList:(id)plist
{
    return [self sessionWithPropertyList:plist];
}

- (NSDictionary *)propertyList
{
    return @{ MIDINetworkKeyIdentifier: self.identifier ?: @"",
              MIDINetworkKeyName: self.name ?: @"",
              MIDINetworkKeyAdvertisedName: self.advertisedName ?: @"",
              MIDINetworkKeyPort: @(self.port),
              MIDINetworkKeyEnabled: @(self.enabled),
              MIDINetworkKeyPolicy: MIDINetworkConnectionPolicyName(self.policy) ?: @"" };
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[self class] sessionWithPropertyList:[self propertyList]];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[MIDINetworkSession class]]
        && [[self propertyList] isEqual:[other propertyList]];
}

- (NSUInteger)hash
{
    return [self.identifier hash];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MIDINetworkSession %@ '%@' port %lu%@>", self.identifier,
            self.name, (unsigned long)self.port, self.enabled ? @" enabled" : @""];
}

@end

#pragma mark - MIDINetworkHost

@implementation MIDINetworkHost

+ (instancetype)manualHostWithName:(NSString *)name address:(NSString *)address port:(NSUInteger)port
{
    MIDINetworkHost *h = [[self alloc] init];
    h.identifier = MIDINetworkMakeIdentifier();
    h.name = name;
    h.address = address;
    h.port = port;
    h.source = MIDINetworkHostSourceManual;
    return h;
}

+ (instancetype)hostWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *identifier = PLString(plist, MIDINetworkKeyIdentifier);
    NSString *name = PLString(plist, MIDINetworkKeyName);
    NSString *address = PLString(plist, MIDINetworkKeyAddress);
    NSNumber *port = PLNumber(plist, MIDINetworkKeyPort);
    NSInteger source;
    if (identifier == nil || name == nil || address == nil || port == nil
        || !PLIndexOfName(PLString(plist, MIDINetworkKeySource), kSourceNames, 2, &source)) {
        return nil;
    }
    MIDINetworkHost *h = [[self alloc] init];
    h.identifier = identifier;
    h.name = name;
    h.address = address;
    h.port = [port unsignedIntegerValue];
    h.source = (MIDINetworkHostSource)source;
    return h;
}

+ (id)modelWithPropertyList:(id)plist
{
    return [self hostWithPropertyList:plist];
}

- (NSDictionary *)propertyList
{
    return @{ MIDINetworkKeyIdentifier: self.identifier ?: @"",
              MIDINetworkKeyName: self.name ?: @"",
              MIDINetworkKeyAddress: self.address ?: @"",
              MIDINetworkKeyPort: @(self.port),
              MIDINetworkKeySource: kSourceNames[self.source == MIDINetworkHostSourceManual ? 1 : 0] };
}

- (BOOL)isManual
{
    return self.source == MIDINetworkHostSourceManual;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[self class] hostWithPropertyList:[self propertyList]];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[MIDINetworkHost class]]
        && [[self propertyList] isEqual:[other propertyList]];
}

- (NSUInteger)hash
{
    return [self.identifier hash];
}

@end

#pragma mark - MIDINetworkParticipant

@implementation MIDINetworkParticipant

+ (instancetype)participantWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *identifier = PLString(plist, MIDINetworkKeyIdentifier);
    NSString *name = PLString(plist, MIDINetworkKeyName);
    NSString *address = PLString(plist, MIDINetworkKeyAddress);
    NSNumber *latency = PLNumber(plist, MIDINetworkKeyLatency);
    NSInteger state;
    if (identifier == nil || name == nil || address == nil || latency == nil
        || !PLIndexOfName(PLString(plist, MIDINetworkKeyState), kStateNames, 2, &state)) {
        return nil;
    }
    MIDINetworkParticipant *p = [[self alloc] init];
    p.identifier = identifier;
    p.name = name;
    p.address = address;
    p.latency = [latency doubleValue];
    p.state = (MIDINetworkParticipantState)state;
    return p;
}

+ (id)modelWithPropertyList:(id)plist
{
    return [self participantWithPropertyList:plist];
}

- (NSDictionary *)propertyList
{
    return @{ MIDINetworkKeyIdentifier: self.identifier ?: @"",
              MIDINetworkKeyName: self.name ?: @"",
              MIDINetworkKeyAddress: self.address ?: @"",
              MIDINetworkKeyLatency: @(self.latency),
              MIDINetworkKeyState: kStateNames[self.state == MIDINetworkParticipantStateConnected ? 1 : 0] };
}

- (BOOL)isConnected
{
    return self.state == MIDINetworkParticipantStateConnected;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[self class] participantWithPropertyList:[self propertyList]];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[MIDINetworkParticipant class]]
        && [[self propertyList] isEqual:[other propertyList]];
}

- (NSUInteger)hash
{
    return [self.identifier hash];
}

@end

#pragma mark - MIDINetworkPort

@implementation MIDINetworkPort

+ (instancetype)portWithIdentifier:(NSString *)identifier name:(NSString *)name
                           canSend:(BOOL)canSend canReceive:(BOOL)canReceive
{
    MIDINetworkPort *p = [[self alloc] init];
    p.identifier = identifier;
    p.name = name;
    p.canSend = canSend;
    p.canReceive = canReceive;
    return p;
}

+ (instancetype)portWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *identifier = PLString(plist, MIDINetworkKeyIdentifier);
    NSString *name = PLString(plist, MIDINetworkKeyName);
    NSNumber *canSend = PLNumber(plist, MIDINetworkKeyCanSend);
    NSNumber *canReceive = PLNumber(plist, MIDINetworkKeyCanReceive);
    if (identifier == nil || name == nil || canSend == nil || canReceive == nil) {
        return nil;
    }
    return [self portWithIdentifier:identifier name:name
                            canSend:[canSend boolValue] canReceive:[canReceive boolValue]];
}

+ (id)modelWithPropertyList:(id)plist
{
    return [self portWithPropertyList:plist];
}

- (NSDictionary *)propertyList
{
    return @{ MIDINetworkKeyIdentifier: self.identifier ?: @"",
              MIDINetworkKeyName: self.name ?: @"",
              MIDINetworkKeyCanSend: @(self.canSend),
              MIDINetworkKeyCanReceive: @(self.canReceive) };
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[self class] portWithPropertyList:[self propertyList]];
}

- (BOOL)isEqual:(id)other
{
    return [other isKindOfClass:[MIDINetworkPort class]]
        && [[self propertyList] isEqual:[other propertyList]];
}

- (NSUInteger)hash
{
    return [self.identifier hash];
}

@end

#pragma mark - MIDINetworkRoute

@implementation MIDINetworkRoute

+ (instancetype)routeForSession:(NSString *)sessionIdentifier
                      inputPort:(NSString *)inputPortIdentifier
                     outputPort:(NSString *)outputPortIdentifier
{
    MIDINetworkRoute *r = [[self alloc] init];
    r.sessionIdentifier = sessionIdentifier;
    r.inputPortIdentifier = inputPortIdentifier;
    r.outputPortIdentifier = outputPortIdentifier;
    return r;
}

+ (instancetype)routeWithPropertyList:(id)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *session = PLString(plist, MIDINetworkKeySession);
    if (session == nil) {
        return nil;
    }
    /* Unrouted directions are absent from the plist, since a property
       list cannot hold nil. */
    id input = [plist objectForKey:MIDINetworkKeyInputPort];
    id output = [plist objectForKey:MIDINetworkKeyOutputPort];
    if ((input != nil && ![input isKindOfClass:[NSString class]])
        || (output != nil && ![output isKindOfClass:[NSString class]])) {
        return nil;
    }
    return [self routeForSession:session inputPort:input outputPort:output];
}

+ (id)modelWithPropertyList:(id)plist
{
    return [self routeWithPropertyList:plist];
}

- (NSDictionary *)propertyList
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:self.sessionIdentifier ?: @"" forKey:MIDINetworkKeySession];
    if (self.inputPortIdentifier != nil) {
        [d setObject:self.inputPortIdentifier forKey:MIDINetworkKeyInputPort];
    }
    if (self.outputPortIdentifier != nil) {
        [d setObject:self.outputPortIdentifier forKey:MIDINetworkKeyOutputPort];
    }
    return d;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[self class] routeWithPropertyList:[self propertyList]];
}

- (BOOL)isEqual:(id)other
{
    if (![other isKindOfClass:[MIDINetworkRoute class]]) {
        return NO;
    }
    MIDINetworkRoute *r = other;
    return PLEqual(self.sessionIdentifier, r.sessionIdentifier)
        && PLEqual(self.inputPortIdentifier, r.inputPortIdentifier)
        && PLEqual(self.outputPortIdentifier, r.outputPortIdentifier);
}

- (NSUInteger)hash
{
    return [self.sessionIdentifier hash];
}

@end

#pragma mark - Arrays

NSArray *MIDINetworkModelsFromPropertyLists(id plists, Class modelClass)
{
    if (![plists isKindOfClass:[NSArray class]]
        || ![modelClass respondsToSelector:@selector(modelWithPropertyList:)]) {
        return nil;
    }
    NSMutableArray *models = [NSMutableArray arrayWithCapacity:[plists count]];
    for (id plist in plists) {
        id model = [(Class<MIDINetworkPropertyListModel>)modelClass modelWithPropertyList:plist];
        if (model == nil) {
            return nil;
        }
        [models addObject:model];
    }
    return models;
}

NSArray *MIDINetworkPropertyListsFromModels(NSArray *models)
{
    NSMutableArray *plists = [NSMutableArray arrayWithCapacity:[models count]];
    for (id<MIDINetworkPropertyListModel> model in models) {
        [plists addObject:[model propertyList]];
    }
    return plists;
}
