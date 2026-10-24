/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMDaemon.h"
#import "GMClock.h"
#import "GMLocalSession.h"
#import "GMPeerConnection.h"
#import "GMSocketAddress.h"
#import "GMUDPEndpoint.h"
#import "GMMIDIPorts.h"
#import "GMServiceDirectory.h"
#import "MIDINetworkState.h"
#import "MIDINetworkBackend.h"
#import "MIDINetworkControl.h"
#include <errno.h>
#include <stdlib.h>

/* Where sessions, manual hosts and routes are kept between logins */
static NSString * const GMDefaultsDomain = @"io.github.gershwin-desktop.gwmidid";
static NSString * const GMKeySessions = @"Sessions";
static NSString * const GMKeyHosts = @"Hosts";
static NSString * const GMKeyRoutes = @"Routes";

/* Name of our sequencer client as applications list it */
static NSString * const GMClientName = @"Network MIDI";

/* Identifiers of hosts found by mDNS: stable for as long as the name is
 * announced, distinct from the identifiers clients make for manual hosts. */
static NSString * const GMDiscoveredPrefix = @"discovered:";

/* Clients redraw on every push; latency changes after each clock sync
 * would otherwise arrive several times a second. */
#define GM_LATENCY_PUSH_INTERVAL 1.0
#define GM_CHANGE_PUSH_DELAY 0.05

/* libs-base sends return values of remote calls as plain objects, never
 * by copy, whatever the protocol says, so a snapshot would reach the
 * client as a proxy and every lookup in it would be another round trip to
 * the daemon (and fail once it has quit).  The control interface only
 * ever passes property lists, so in this process they always travel by
 * copy. */
@implementation NSDictionary (GMControlByCopy)
- (id) replacementObjectForPortCoder: (NSPortCoder *)coder
{
  return self;
}
@end

@implementation NSArray (GMControlByCopy)
- (id) replacementObjectForPortCoder: (NSPortCoder *)coder
{
  return self;
}
@end

static GMConnectionPolicy GMPolicyFor(MIDINetworkConnectionPolicy p)
{
  switch (p)
    {
      case MIDINetworkConnectionPolicyAnyone: return GMConnectionPolicyAnyone;
      case MIDINetworkConnectionPolicyDirectoryOnly: return GMConnectionPolicyDirectory;
      case MIDINetworkConnectionPolicyNobody: return GMConnectionPolicyNobody;
    }
  return GMConnectionPolicyNobody;
}

static NSString *GMParticipantIdentifier(GMPeerConnection *p)
{
  return [NSString stringWithFormat: @"%08x", p.token];
}

/* What runs for one enabled session */
@interface GMRunningSession : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) GMLocalSession *session;
@property (nonatomic, strong) GMUDPEndpoint *endpoint;
@property (nonatomic) int midiPort;
@property (nonatomic, copy) NSString *announcedName;
@property (nonatomic, strong) MIDINetworkRoute *appliedRoute;
@end

@implementation GMRunningSession
@end

@interface GMDaemon () <GMLocalSessionDelegate, GMMIDIPortsDelegate,
  GMServiceDirectoryDelegate>
@end

@implementation GMDaemon
{
  MIDINetworkState *_state;
  NSMutableDictionary *_running;      /* session identifier -> GMRunningSession */
  id<GMMIDIPorts> _ports;
  GMServiceDirectory *_directory;
  NSConnection *_connection;
  NSMutableArray *_clients;           /* proxies of MIDINetworkDaemonClient */
  NSTimer *_timer;
  NSTimeInterval _epoch;
  NSMutableSet *_pendingSections;
  BOOL _pushScheduled;
  NSTimeInterval _lastLatencyPush;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _state = [MIDINetworkState new];
      _running = [NSMutableDictionary dictionary];
      _clients = [NSMutableArray array];
      _pendingSections = [NSMutableSet set];
      _epoch = GMMonotonicNow();
    }
  return self;
}

#pragma mark - Start and stop

- (BOOL) startWithError: (NSString **)error
{
  NSError *err = nil;

  /* The name doubles as the single-instance lock per user. */
  _connection = [NSConnection connectionWithReceivePort: [NSMessagePort port]
                                               sendPort: nil];
  [_connection setRootObject: self];
  if (![_connection registerName: MIDINetworkDaemonServiceName()
                  withNameServer: [NSMessagePortNameServer sharedInstance]])
    {
      if (error) *error = @"another gwmidid is already running for this user";
      [_connection invalidate];
      _connection = nil;
      return NO;
    }
  [[NSNotificationCenter defaultCenter] addObserver: self
    selector: @selector(connectionDidDie:)
        name: NSConnectionDidDieNotification object: nil];

  _ports = GMMIDIPortsOpen(GMClientName, &err);
  if (_ports == nil)
    {
      if (error) *error = [err localizedDescription];
      return NO;
    }
  _ports.delegate = self;
  NSLog(@"gwmidid: MIDI ports on %@", [_ports portLayerDescription]);
  [self refreshLocalPorts];

  _directory = [GMServiceDirectory new];
  _directory.delegate = self;
  [_directory startBrowsing];

  [self loadConfiguration];
  [self reschedule];
  return YES;
}

- (void) loadConfiguration
{
  NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
    persistentDomainForName: GMDefaultsDomain];
  NSError *err = nil;

  for (id plist in [domain objectForKey: GMKeyHosts])
    {
      MIDINetworkHost *h = [MIDINetworkHost hostWithPropertyList: plist];
      if (h == nil || ![_state addManualHost: h error: &err])
        NSLog(@"gwmidid: stored host %@ refused: %@", plist,
          h ? [err localizedDescription] : @"malformed");
    }
  for (id plist in [domain objectForKey: GMKeySessions])
    {
      MIDINetworkSession *s = [MIDINetworkSession sessionWithPropertyList: plist];
      BOOL wanted = s.enabled;
      if (s == nil)
        {
          NSLog(@"gwmidid: stored session %@ refused: malformed", plist);
          continue;
        }
      s.enabled = NO;
      if (![_state addSession: s error: &err])
        {
          NSLog(@"gwmidid: stored session \"%@\" refused: %@", s.name,
            [err localizedDescription]);
          continue;
        }
      if (wanted && ![self enableSession: s.identifier error: &err])
        NSLog(@"gwmidid: session \"%@\" not started: %@", s.name,
          [err localizedDescription]);
    }
  for (id plist in [domain objectForKey: GMKeyRoutes])
    {
      MIDINetworkRoute *r = [MIDINetworkRoute routeWithPropertyList: plist];
      if (r == nil || ![_state setRoute: r error: &err])
        NSLog(@"gwmidid: stored route %@ not restored: %@", plist,
          r ? [err localizedDescription] : @"malformed");
      else
        [self applyRouteOfSession: r.sessionIdentifier];
    }
}

- (void) saveConfiguration
{
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  NSMutableArray *hosts = [NSMutableArray array];
  NSMutableArray *routes = [NSMutableArray array];

  for (MIDINetworkHost *h in [_state directory])
    if ([h isManual]) [hosts addObject: [h propertyList]];
  for (MIDINetworkSession *s in [_state sessions])
    {
      MIDINetworkRoute *r = [_state routeForSessionWithIdentifier: s.identifier];
      if (r.inputPortIdentifier || r.outputPortIdentifier)
        [routes addObject: [r propertyList]];
    }
  [ud setPersistentDomain: @{
      GMKeySessions: MIDINetworkPropertyListsFromModels([_state sessions]),
      GMKeyHosts: hosts, GMKeyRoutes: routes }
                  forName: GMDefaultsDomain];
  [ud synchronize];
}

- (void) shutdown
{
  for (GMRunningSession *rs in [_running allValues]) [self stopRunning: rs];
  [_running removeAllObjects];
  [_directory withdrawAll];
  [_directory stopBrowsing];
  [_ports close];
  [_timer invalidate];
  _timer = nil;
  [[NSNotificationCenter defaultCenter] removeObserver: self];
  [_connection registerName: nil
             withNameServer: [NSMessagePortNameServer sharedInstance]];
  [_connection invalidate];
  _connection = nil;
}

#pragma mark - Running sessions

/* Opens the sockets, the MIDI port and the announcement.  The state is
 * not touched, so a failure leaves everything as it was. */
- (GMRunningSession *) startRunning: (MIDINetworkSession *)s error: (NSError **)error
{
  GMRunningSession *rs = [GMRunningSession new];
  NSError *err = nil;
  GMLocalSession *ls;
  __weak GMDaemon *weakSelf = self;

  ls = [[GMLocalSession alloc] initWithName: s.advertisedName
                                       port: (uint16_t)s.port
                                       ssrc: arc4random()
                                 clockEpoch: _epoch];
  rs.identifier = s.identifier;
  rs.endpoint = [[GMUDPEndpoint alloc] initWithPort: (uint16_t)s.port
    handler: ^(NSData *data, NSData *from, BOOL control) {
      [ls receiveDatagram: data from: from onControl: control
                       at: GMMonotonicNow()];
      [weakSelf reschedule];
    } error: &err];
  if (rs.endpoint == nil)
    {
      NSLog(@"gwmidid: session \"%@\": %@", s.name, [err localizedDescription]);
      if (error)
        *error = ([err code] == EADDRINUSE)
          ? MIDINetworkMakeError(MIDINetworkErrorPortInUse,
              @"Another program already uses this port or the one above it.")
          : MIDINetworkMakeError(MIDINetworkErrorUnavailable,
              @"The session's network port could not be opened.");
      return nil;
    }
  rs.midiPort = [_ports createPortNamed: s.name error: &err];
  if (rs.midiPort < 0)
    {
      NSLog(@"gwmidid: session \"%@\": %@", s.name, [err localizedDescription]);
      [rs.endpoint close];
      if (error)
        *error = MIDINetworkMakeError(MIDINetworkErrorUnavailable,
          @"The session's MIDI port could not be created.");
      return nil;
    }
  ls.transport = rs.endpoint;
  ls.delegate = self;
  ls.policy = GMPolicyFor(s.policy);
  rs.session = ls;
  rs.announcedName = s.advertisedName;
  [_directory announceSessionNamed: s.advertisedName port: (uint16_t)s.port];
  NSLog(@"gwmidid: session \"%@\" (announced as \"%@\") on UDP %lu/%lu, "
    @"MIDI port %@", s.name, s.advertisedName, (unsigned long)s.port,
    (unsigned long)s.port + 1, [_ports addressOfPort: rs.midiPort]);
  return rs;
}

- (void) stopRunning: (GMRunningSession *)rs
{
  [rs.session closeAllAt: GMMonotonicNow()];
  rs.session.delegate = nil;
  [_directory withdrawSessionNamed: rs.announcedName];
  [_ports removePort: rs.midiPort];
  [rs.endpoint close];
  rs.session = nil;
  rs.endpoint = nil;
}

- (BOOL) enableSession: (NSString *)identifier error: (NSError **)error
{
  MIDINetworkSession *s = [_state sessionWithIdentifier: identifier];
  GMRunningSession *rs;

  if (s == nil)
    return [_state setEnabled: YES forSessionWithIdentifier: identifier
                        error: error];
  if ([_running objectForKey: identifier] != nil) return YES;
  rs = [self startRunning: s error: error];
  if (rs == nil) return NO;
  if (![_state setEnabled: YES forSessionWithIdentifier: identifier error: error])
    {
      [self stopRunning: rs];
      return NO;
    }
  [_running setObject: rs forKey: identifier];
  [self applyRouteOfSession: identifier];
  return YES;
}

- (void) disableSession: (NSString *)identifier
{
  GMRunningSession *rs = [_running objectForKey: identifier];
  if (rs == nil) return;
  [self stopRunning: rs];
  [_running removeObjectForKey: identifier];
}

/* Makes the sequencer connections match the session's route. */
- (void) applyRouteOfSession: (NSString *)identifier
{
  GMRunningSession *rs = [_running objectForKey: identifier];
  MIDINetworkRoute *want = [_state routeForSessionWithIdentifier: identifier];
  MIDINetworkRoute *had = rs.appliedRoute;
  NSError *err = nil;

  if (rs == nil) return;
  if (had.inputPortIdentifier
    && ![had.inputPortIdentifier isEqual: want.inputPortIdentifier])
    [_ports disconnectPort: rs.midiPort fromLocalPort: had.inputPortIdentifier
                     input: YES];
  if (had.outputPortIdentifier
    && ![had.outputPortIdentifier isEqual: want.outputPortIdentifier])
    [_ports disconnectPort: rs.midiPort fromLocalPort: had.outputPortIdentifier
                     input: NO];
  if (want.inputPortIdentifier
    && ![_ports connectPort: rs.midiPort toLocalPort: want.inputPortIdentifier
                      input: YES error: &err])
    NSLog(@"gwmidid: route: %@", [err localizedDescription]);
  if (want.outputPortIdentifier
    && ![_ports connectPort: rs.midiPort toLocalPort: want.outputPortIdentifier
                      input: NO error: &err])
    NSLog(@"gwmidid: route: %@", [err localizedDescription]);
  rs.appliedRoute = [want copy];
}

- (GMRunningSession *) runningFor: (GMLocalSession *)session
{
  for (GMRunningSession *rs in [_running allValues])
    if (rs.session == session) return rs;
  return nil;
}

/* Brings the session's participants in the state in line with the
 * protocol's view of them. */
- (void) syncParticipantsOf: (GMRunningSession *)rs
{
  NSMutableSet *live = [NSMutableSet set];
  NSError *err = nil;

  if (rs == nil) return;
  for (GMPeerConnection *p in rs.session.peers)
    {
      MIDINetworkParticipant *mp = [MIDINetworkParticipant new];
      mp.identifier = GMParticipantIdentifier(p);
      mp.name = [p.remoteName length] ? p.remoteName
        : GMAddressDescription(p.controlAddress);
      mp.address = GMAddressDescription(p.controlAddress);
      mp.latency = p.latency < 0 ? -1.0 : p.latency * 1000.0;
      mp.state = (p.state == GMPeerStateConnected)
        ? MIDINetworkParticipantStateConnected
        : MIDINetworkParticipantStateInviting;
      [live addObject: mp.identifier];
      if (![_state replaceParticipant: mp inSession: rs.identifier]
        && ![_state addParticipant: mp toSession: rs.identifier error: &err])
        NSLog(@"gwmidid: participant %@: %@", mp.name, [err localizedDescription]);
    }
  for (MIDINetworkParticipant *mp in
       [_state participantsForSessionWithIdentifier: rs.identifier])
    if (![live containsObject: mp.identifier])
      [_state removeParticipantWithIdentifier: mp.identifier
                                  fromSession: rs.identifier error: NULL];
}

#pragma mark - Timers

/* One timer for everything, set to the earliest deadline of any
 * participant, so an idle daemon does not wake up at all. */
- (void) reschedule
{
  NSTimeInterval next = 0;
  for (GMRunningSession *rs in [_running allValues])
    {
      NSTimeInterval d = [rs.session nextDeadline];
      if (d != 0 && (next == 0 || d < next)) next = d;
    }
  [_timer invalidate];
  _timer = nil;
  if (next == 0) return;
  _timer = [NSTimer scheduledTimerWithTimeInterval:
      MAX(next - GMMonotonicNow(), 0.001)
                                            target: self
                                          selector: @selector(timerFired:)
                                          userInfo: nil
                                           repeats: NO];
}

- (void) timerFired: (NSTimer *)t
{
  NSTimeInterval now = GMMonotonicNow();
  _timer = nil;
  for (GMRunningSession *rs in [_running allValues])
    [rs.session fireTimersAt: now];
  [self reschedule];
}

#pragma mark - Pushing changes to clients

- (NSDictionary *) sections: (NSArray *)keys
{
  NSDictionary *all = [_state propertyList];
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  for (NSString *k in keys) [d setObject: [all objectForKey: k] forKey: k];
  return d;
}

/* Coalesced: a burst of changes (a session starting, a clock sync round)
 * reaches the clients as one message. */
- (void) push: (NSArray *)keys
{
  [_pendingSections addObjectsFromArray: keys];
  if (_pushScheduled) return;
  _pushScheduled = YES;
  [self performSelector: @selector(flushPush) withObject: nil
             afterDelay: GM_CHANGE_PUSH_DELAY];
}

- (void) flushPush
{
  NSDictionary *changes = [self sections: [_pendingSections allObjects]];
  _pushScheduled = NO;
  [_pendingSections removeAllObjects];
  if ([changes count] == 0) return;
  for (id client in [_clients copy])
    {
      @try
        {
          [client daemonDidChange: changes];
        }
      @catch (NSException *e)
        {
          [_clients removeObject: client];
        }
    }
}

- (void) broadcastError: (NSError *)error
{
  NSDictionary *e = @{ MIDINetworkErrorKeyCode: @([error code]),
                       MIDINetworkErrorKeyMessage: [error localizedDescription] };
  for (id client in [_clients copy])
    {
      @try
        {
          [client daemonDidEncounterError: e];
        }
      @catch (NSException *x)
        {
          [_clients removeObject: client];
        }
    }
}

- (void) connectionDidDie: (NSNotification *)n
{
  NSConnection *dead = [n object];
  for (id client in [_clients copy])
    if ([client isProxy] && [(NSDistantObject *)client connectionForProxy] == dead)
      [_clients removeObject: client];
}

/* Reply for a client's change: the touched sections, also pushed to every
 * client so that the others see it too. */
- (NSDictionary *) reply: (BOOL)ok error: (NSError *)error sections: (NSArray *)keys
{
  if (!ok) return MIDINetworkReplyWithError(error);
  [self saveConfiguration];
  [self push: keys];
  return MIDINetworkReplyWithChanges([self sections: keys]);
}

#pragma mark - Protocol events

- (void) session: (GMLocalSession *)session
  didReceiveMIDIMessages: (NSArray *)messages
                fromPeer: (GMPeerConnection *)peer
{
  GMRunningSession *rs = [self runningFor: session];
  if (rs) [_ports sendMessages: messages fromPort: rs.midiPort];
}

- (void) ports: (id<GMMIDIPorts>)ports
  didReceiveMessages: (NSArray *)messages
              onPort: (int)port
{
  for (GMRunningSession *rs in [_running allValues])
    if (rs.midiPort == port)
      [rs.session sendMIDIMessages: messages at: GMMonotonicNow()];
  [self reschedule];
}

- (void) refreshLocalPorts
{
  NSMutableArray *ports = [NSMutableArray array];
  for (NSDictionary *d in [_ports localPorts])
    [ports addObject: [MIDINetworkPort
      portWithIdentifier: [d objectForKey: GMLocalPortIdentifier]
                    name: [d objectForKey: GMLocalPortName]
                 canSend: [[d objectForKey: GMLocalPortCanSend] boolValue]
              canReceive: [[d objectForKey: GMLocalPortCanReceive] boolValue]]];
  [_state setLocalPorts: ports];
}

- (void) portsDidChangeLocalPorts: (id<GMMIDIPorts>)ports
{
  NSArray *before = [[_state propertyList] objectForKey: MIDINetworkStateKeyRoutes];
  [self refreshLocalPorts];
  for (NSString *ident in [_running allKeys]) [self applyRouteOfSession: ident];
  /* A vanished port leaves its routes; that is a configuration change. */
  if (![before isEqual: [[_state propertyList] objectForKey: MIDINetworkStateKeyRoutes]])
    [self saveConfiguration];
  [self push: @[ MIDINetworkStateKeyLocalPorts, MIDINetworkStateKeyRoutes ]];
}

- (BOOL) session: (GMLocalSession *)session
  directoryAllowsAddress: (NSData *)address
                    name: (NSString *)name
{
  NSString *host = GMAddressHost(address);
  for (MIDINetworkHost *h in [_state directory])
    {
      NSData *a = GMAddressFromNumericHost(h.address, 1);
      if (a != nil && [GMAddressHost(a) isEqualToString: host]) return YES;
    }
  return NO;
}

- (void) sessionParticipantsDidChange: (GMLocalSession *)session
{
  [self syncParticipantsOf: [self runningFor: session]];
  [self push: @[ MIDINetworkStateKeyParticipants ]];
}

- (void) sessionParticipantLatencyDidChange: (GMLocalSession *)session
{
  NSTimeInterval now = GMMonotonicNow();
  [self syncParticipantsOf: [self runningFor: session]];
  if (now - _lastLatencyPush >= GM_LATENCY_PUSH_INTERVAL)
    {
      _lastLatencyPush = now;
      [self push: @[ MIDINetworkStateKeyParticipants ]];
    }
}

- (void) session: (GMLocalSession *)session peerDidClose: (GMPeerConnection *)peer
{
  /* Only our own invitations have someone waiting for their outcome. */
  if (peer.role != GMPeerRoleInitiator)
    return;
  if (peer.closeReason == GMPeerCloseReasonRejected)
    [self broadcastError: MIDINetworkMakeStandardError(MIDINetworkErrorPeerRejected)];
  else if (peer.closeReason == GMPeerCloseReasonTimeout)
    [self broadcastError: MIDINetworkMakeError(MIDINetworkErrorTimeout,
      @"The other computer did not answer.")];
}

- (void) serviceDirectoryDidChange: (GMServiceDirectory *)directory
{
  NSMutableArray *hosts = [NSMutableArray array];
  for (GMDiscoveredService *svc in [_directory services])
    {
      MIDINetworkHost *h;
      if ([svc.addresses count] == 0) continue;  /* not resolved yet */
      h = [MIDINetworkHost new];
      h.identifier = [GMDiscoveredPrefix stringByAppendingString: svc.name];
      h.name = svc.name;
      h.address = GMAddressHost([svc.addresses objectAtIndex: 0]);
      h.port = svc.port;
      h.source = MIDINetworkHostSourceDiscovered;
      [hosts addObject: h];
    }
  [_state setDiscoveredHosts: hosts];
  [self push: @[ MIDINetworkStateKeyDirectory ]];
}

#pragma mark - MIDINetworkDaemonControl

- (int) protocolVersion
{
  return MIDINETWORK_CONTROL_PROTOCOL_VERSION;
}

- (bycopy NSDictionary *) snapshot
{
  return [_state propertyList];
}

- (void) registerClient: (id<MIDINetworkDaemonClient>)client
{
  if (client != nil && ![_clients containsObject: client])
    [_clients addObject: client];
}

- (void) unregisterClient: (id<MIDINetworkDaemonClient>)client
{
  [_clients removeObject: client];
}

- (bycopy NSDictionary *) addSession: (bycopy NSDictionary *)plist
{
  NSError *e = nil;
  MIDINetworkSession *s = [MIDINetworkSession sessionWithPropertyList: plist];
  BOOL wanted = s.enabled, ok;

  if (s == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeStandardError(
      MIDINetworkErrorInvalidArgument));
  s.enabled = NO;
  ok = [_state addSession: s error: &e];
  if (ok && wanted && ![self enableSession: s.identifier error: &e])
    {
      [_state removeSessionWithIdentifier: s.identifier error: NULL];
      ok = NO;
    }
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeySessions ]];
}

- (bycopy NSDictionary *) removeSession: (bycopy NSString *)identifier
{
  NSError *e = nil;
  BOOL ok;
  if ([_state sessionWithIdentifier: identifier] != nil)
    [self disableSession: identifier];
  ok = [_state removeSessionWithIdentifier: identifier error: &e];
  [self reschedule];
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeySessions,
    MIDINetworkStateKeyParticipants, MIDINetworkStateKeyRoutes ]];
}

- (bycopy NSDictionary *) updateSession: (bycopy NSDictionary *)plist
{
  NSError *e = nil;
  MIDINetworkSession *s = [MIDINetworkSession sessionWithPropertyList: plist];
  MIDINetworkSession *old;
  GMRunningSession *rs;

  if (s == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeStandardError(
      MIDINetworkErrorInvalidArgument));
  old = [[_state sessionWithIdentifier: s.identifier] copy];
  rs = [_running objectForKey: s.identifier];
  if (![_state updateSession: s error: &e])
    return MIDINetworkReplyWithError(e);
  s = [_state sessionWithIdentifier: s.identifier];
  if (rs != nil)
    {
      if (s.port != old.port || ![s.advertisedName isEqual: old.advertisedName])
        {
          /* New sockets and a new announcement: the participants knew the
           * old ones and have to connect again. */
          GMRunningSession *fresh;
          [self disableSession: s.identifier];
          fresh = [self startRunning: s error: &e];
          if (fresh == nil)
            {
              /* Put back what worked, so a failure changes nothing. */
              [_state updateSession: old error: NULL];
              fresh = [self startRunning: old error: NULL];
              if (fresh) [_running setObject: fresh forKey: old.identifier];
              [self applyRouteOfSession: old.identifier];
              [self syncParticipantsOf: fresh];
              [self push: @[ MIDINetworkStateKeyParticipants ]];
              return MIDINetworkReplyWithError(e);
            }
          [_running setObject: fresh forKey: s.identifier];
          [self applyRouteOfSession: s.identifier];
          [self syncParticipantsOf: fresh];
        }
      else
        {
          if (![s.name isEqual: old.name])
            [_ports renamePort: rs.midiPort to: s.name];
          rs.session.policy = GMPolicyFor(s.policy);
        }
    }
  [self reschedule];
  return [self reply: YES error: nil sections: @[ MIDINetworkStateKeySessions,
    MIDINetworkStateKeyParticipants ]];
}

- (bycopy NSDictionary *) setEnabled: (BOOL)enabled
                          forSession: (bycopy NSString *)identifier
{
  NSError *e = nil;
  BOOL ok;
  if (enabled)
    ok = [self enableSession: identifier error: &e];
  else
    {
      ok = [_state setEnabled: NO forSessionWithIdentifier: identifier error: &e];
      if (ok) [self disableSession: identifier];
    }
  [self reschedule];
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeySessions,
    MIDINetworkStateKeyParticipants ]];
}

- (bycopy NSDictionary *) addManualHost: (bycopy NSDictionary *)plist
{
  NSError *e = nil;
  MIDINetworkHost *h = [MIDINetworkHost hostWithPropertyList: plist];
  BOOL ok;
  if (h == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeStandardError(
      MIDINetworkErrorInvalidArgument));
  /* Matching incoming invitations and inviting both need an address the
   * daemon can use without a blocking name lookup. */
  if (GMAddressFromNumericHost(h.address, 1) == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeError(
      MIDINetworkErrorInvalidArgument,
      @"The address must be a numeric IP address."));
  ok = [_state addManualHost: h error: &e];
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeyDirectory ]];
}

- (bycopy NSDictionary *) removeHost: (bycopy NSString *)identifier
{
  NSError *e = nil;
  BOOL ok = [_state removeHostWithIdentifier: identifier error: &e];
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeyDirectory ]];
}

- (bycopy NSDictionary *) connectSession: (bycopy NSString *)sessionIdentifier
                                  toHost: (bycopy NSString *)hostIdentifier
{
  NSError *e = nil;
  MIDINetworkHost *h;
  GMRunningSession *rs;
  NSData *addr;

  if (![_state validateConnectSession: sessionIdentifier toHost: hostIdentifier
                                error: &e])
    return MIDINetworkReplyWithError(e);
  h = [_state hostWithIdentifier: hostIdentifier];
  rs = [_running objectForKey: sessionIdentifier];
  addr = GMAddressFromNumericHost(h.address, (uint16_t)h.port);
  if (addr == nil || rs == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeError(
      MIDINetworkErrorInvalidArgument,
      @"The address must be a numeric IP address."));
  if ([GMAddressHost(addr) rangeOfString: @":"].location != NSNotFound)
    return MIDINetworkReplyWithError(MIDINetworkMakeError(
      MIDINetworkErrorInvalidArgument,
      @"Connections over IPv6 are not supported yet."));
  [rs.session inviteAddress: addr at: GMMonotonicNow()];
  [self reschedule];
  /* The participant is in the state as inviting by now, through the
   * session's change notification. */
  return [self reply: YES error: nil sections: @[ MIDINetworkStateKeyParticipants ]];
}

- (bycopy NSDictionary *) disconnectParticipant: (bycopy NSString *)participantIdentifier
                                    fromSession: (bycopy NSString *)sessionIdentifier
{
  GMRunningSession *rs = [_running objectForKey: sessionIdentifier];
  for (GMPeerConnection *p in rs.session.peers)
    {
      if ([GMParticipantIdentifier(p) isEqual: participantIdentifier])
        {
          [rs.session closePeer: p at: GMMonotonicNow()];
          [self reschedule];
          return [self reply: YES error: nil
                    sections: @[ MIDINetworkStateKeyParticipants ]];
        }
    }
  return MIDINetworkReplyWithError(MIDINetworkMakeError(
    MIDINetworkErrorInvalidArgument, @"The participant is not connected."));
}

- (bycopy NSDictionary *) setRoute: (bycopy NSDictionary *)plist
{
  NSError *e = nil;
  MIDINetworkRoute *r = [MIDINetworkRoute routeWithPropertyList: plist];
  BOOL ok;
  if (r == nil)
    return MIDINetworkReplyWithError(MIDINetworkMakeStandardError(
      MIDINetworkErrorInvalidArgument));
  ok = [_state setRoute: r error: &e];
  if (ok) [self applyRouteOfSession: r.sessionIdentifier];
  return [self reply: ok error: e sections: @[ MIDINetworkStateKeyRoutes ]];
}

@end
