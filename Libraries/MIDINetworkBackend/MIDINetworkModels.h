/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/*
 * Value objects of network MIDI: sessions this computer offers, hosts it
 * knows about, peers connected to a session, local MIDI ports and the
 * routing between a session and those ports.
 *
 * Every model converts to and from a property list. That one form is what
 * the gwmidid control interface carries (see CONTROL-INTERFACE.md), so the
 * pane, the daemon and the tests can never disagree about field names.
 * The names do not mention a wire protocol on purpose: the same models are
 * meant to describe Network MIDI 2.0 sessions later.
 */

#ifndef MIDINETWORK_MODELS_H
#define MIDINETWORK_MODELS_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MIDINetworkConnectionPolicy) {
    MIDINetworkConnectionPolicyAnyone = 0,
    MIDINetworkConnectionPolicyDirectoryOnly,
    MIDINetworkConnectionPolicyNobody
};

typedef NS_ENUM(NSInteger, MIDINetworkHostSource) {
    MIDINetworkHostSourceDiscovered = 0,
    MIDINetworkHostSourceManual
};

typedef NS_ENUM(NSInteger, MIDINetworkParticipantState) {
    MIDINetworkParticipantStateInviting = 0,
    MIDINetworkParticipantStateConnected
};

/* Property-list keys; the daemon uses the same constants. */
extern NSString * const MIDINetworkKeyIdentifier;
extern NSString * const MIDINetworkKeyName;
extern NSString * const MIDINetworkKeyAdvertisedName;
extern NSString * const MIDINetworkKeyPort;
extern NSString * const MIDINetworkKeyEnabled;
extern NSString * const MIDINetworkKeyPolicy;
extern NSString * const MIDINetworkKeyAddress;
extern NSString * const MIDINetworkKeySource;
extern NSString * const MIDINetworkKeyLatency;
extern NSString * const MIDINetworkKeyState;
extern NSString * const MIDINetworkKeySession;
extern NSString * const MIDINetworkKeyInputPort;
extern NSString * const MIDINetworkKeyOutputPort;
extern NSString * const MIDINetworkKeyCanSend;
extern NSString * const MIDINetworkKeyCanReceive;

/* Policy and source travel as strings so a log or a hand-written test
   plist stays readable. */
NSString *MIDINetworkConnectionPolicyName(MIDINetworkConnectionPolicy policy);
BOOL MIDINetworkConnectionPolicyFromName(NSString *name, MIDINetworkConnectionPolicy *policy);

/* An identifier unique enough for objects created on this computer. */
NSString *MIDINetworkMakeIdentifier(void);

@interface MIDINetworkSession : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;            /* local MIDI port name */
@property (nonatomic, copy) NSString *advertisedName;  /* name other computers see */
@property (nonatomic) NSUInteger port;                 /* UDP control port; data uses port + 1 */
@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic) MIDINetworkConnectionPolicy policy;

/* A new, disabled session with a fresh identifier. */
+ (instancetype)sessionWithName:(NSString *)name port:(NSUInteger)port;
/* nil when a required key is missing or has the wrong type. */
+ (instancetype)sessionWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
@end

@interface MIDINetworkHost : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *address;
@property (nonatomic) NSUInteger port;
@property (nonatomic) MIDINetworkHostSource source;

+ (instancetype)manualHostWithName:(NSString *)name address:(NSString *)address port:(NSUInteger)port;
+ (instancetype)hostWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
- (BOOL)isManual;
@end

@interface MIDINetworkParticipant : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *address;
@property (nonatomic) double latency;                  /* milliseconds, < 0 = not measured yet */
@property (nonatomic) MIDINetworkParticipantState state;

+ (instancetype)participantWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
- (BOOL)isConnected;
@end

/* A local MIDI port a session can be routed to or from. */
@interface MIDINetworkPort : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL canSend;                    /* the port produces MIDI (a keyboard) */
@property (nonatomic) BOOL canReceive;                 /* the port consumes MIDI (a synth) */

+ (instancetype)portWithIdentifier:(NSString *)identifier name:(NSString *)name
                           canSend:(BOOL)canSend canReceive:(BOOL)canReceive;
+ (instancetype)portWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
@end

/* What a session plays into and out of on this computer. A nil port means
   the direction is not routed. */
@interface MIDINetworkRoute : NSObject <NSCopying>
@property (nonatomic, copy) NSString *sessionIdentifier;
@property (nonatomic, copy) NSString *inputPortIdentifier;   /* local port -> session */
@property (nonatomic, copy) NSString *outputPortIdentifier;  /* session -> local port */

+ (instancetype)routeForSession:(NSString *)sessionIdentifier
                      inputPort:(NSString *)inputPortIdentifier
                     outputPort:(NSString *)outputPortIdentifier;
+ (instancetype)routeWithPropertyList:(id)plist;
- (NSDictionary *)propertyList;
@end

/* Map an array of property lists to models; nil if any element is bad, so
   a malformed daemon reply is noticed instead of half applied. */
NSArray *MIDINetworkModelsFromPropertyLists(id plists, Class modelClass);
NSArray *MIDINetworkPropertyListsFromModels(NSArray *models);

#endif
