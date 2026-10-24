/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMDaemon.h"
#import "GMClock.h"
#import "GMConfiguration.h"
#import "GMLocalSession.h"
#import "GMPeerConnection.h"
#import "GMSocketAddress.h"
#import "GMUDPEndpoint.h"
#import "GMMIDIPorts.h"
#import "GMServiceDirectory.h"
#include <stdlib.h>

/* Name of our sequencer client as applications list it */
static NSString * const GMClientName = @"Network MIDI";

@interface GMRunningSession : NSObject
@property (nonatomic, strong) GMSessionConfiguration *configuration;
@property (nonatomic, strong) GMLocalSession *session;
@property (nonatomic, strong) GMUDPEndpoint *endpoint;
@property (nonatomic) int midiPort;
@property (nonatomic, copy) NSString *error;
@end

@implementation GMRunningSession
@end

/* libs-base sends return values of remote calls as plain objects, never
 * by copy, whatever the protocol says, so a status dictionary would reach
 * the client as a proxy and every lookup in it would be another round trip
 * to the daemon (and fail once it has quit).  The control interface only
 * ever returns property lists, so in this process they always travel by
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

@interface GMDaemon () <GMLocalSessionDelegate, GMMIDIPortsDelegate,
  GMServiceDirectoryDelegate>
@end

@implementation GMDaemon
{
  GMConfiguration *_configuration;
  NSMutableArray *_running;           /* GMRunningSession, config order */
  id<GMMIDIPorts> _ports;
  GMServiceDirectory *_directory;
  NSConnection *_connection;
  NSTimer *_timer;
  NSTimeInterval _epoch;
  BOOL _notePending;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _running = [NSMutableArray array];
      _epoch = GMMonotonicNow();
    }
  return self;
}

#pragma mark - Start and stop

- (NSString *) defaultSessionName
{
  NSString *host = [[NSProcessInfo processInfo] hostName];
  NSRange dot = [host rangeOfString: @"."];
  return dot.location == NSNotFound ? host : [host substringToIndex: dot.location];
}

- (BOOL) startWithError: (NSString **)error
{
  NSError *err = nil;
  NSDictionary *domain;

  /* The name doubles as the single-instance lock per user. */
  _connection = [NSConnection connectionWithReceivePort: [NSMessagePort port]
                                               sendPort: nil];
  [_connection setRootObject: self];
  if (![_connection registerName: GMDefaultsDomain
                  withNameServer: [NSMessagePortNameServer sharedInstance]])
    {
      if (error) *error = @"another gwmidid is already running for this user";
      [_connection invalidate];
      _connection = nil;
      return NO;
    }

  _ports = GMMIDIPortsOpen(GMClientName, &err);
  if (_ports == nil)
    {
      if (error) *error = [err localizedDescription];
      return NO;
    }
  _ports.delegate = self;
  NSLog(@"gwmidid: MIDI ports on %@", [_ports portLayerDescription]);

  _directory = [GMServiceDirectory new];
  _directory.delegate = self;
  [_directory startBrowsing];

  domain = [[NSUserDefaults standardUserDefaults]
    persistentDomainForName: GMDefaultsDomain];
  _configuration = [GMConfiguration configurationWithDomain: domain
                                                defaultName: [self defaultSessionName]];
  for (NSString *e in _configuration.errors)
    NSLog(@"gwmidid: configuration: %@", e);
  for (GMSessionConfiguration *c in _configuration.sessions)
    [_running addObject: [self startSession: c]];
  for (GMConnectionConfiguration *k in _configuration.connections)
    if (k.host != nil)
      [self connectSession: k.session
                        to: [NSString stringWithFormat: @"%@:%u", k.host, k.port]];
  [self reschedule];
  return YES;
}

- (GMRunningSession *) startSession: (GMSessionConfiguration *)c
{
  GMRunningSession *rs = [GMRunningSession new];
  NSError *err = nil;
  GMLocalSession *s;
  __weak GMDaemon *weakSelf = self;

  rs.configuration = c;
  rs.midiPort = -1;
  if (!c.enabled) return rs;

  s = [[GMLocalSession alloc] initWithName: c.name port: c.port
                                      ssrc: arc4random() clockEpoch: _epoch];
  rs.endpoint = [[GMUDPEndpoint alloc] initWithPort: c.port
    handler: ^(NSData *data, NSData *from, BOOL control) {
      [s receiveDatagram: data from: from onControl: control
                      at: GMMonotonicNow()];
      [weakSelf reschedule];
    } error: &err];
  if (rs.endpoint == nil)
    {
      rs.error = [err localizedDescription];
      NSLog(@"gwmidid: session \"%@\" not started: %@", c.name, rs.error);
      return rs;
    }
  rs.midiPort = [_ports createPortNamed: c.name error: &err];
  if (rs.midiPort < 0)
    {
      rs.error = [err localizedDescription];
      NSLog(@"gwmidid: session \"%@\" not started: %@", c.name, rs.error);
      [rs.endpoint close];
      rs.endpoint = nil;
      return rs;
    }
  s.transport = rs.endpoint;
  s.delegate = self;
  s.policy = c.policy;
  rs.session = s;
  if (c.announce)
    [_directory announceSessionNamed: c.name port: c.port];
  NSLog(@"gwmidid: session \"%@\" on UDP %u/%u, policy %@", c.name, c.port,
    c.port + 1, GMConnectionPolicyString(c.policy));
  return rs;
}

- (void) stopSession: (GMRunningSession *)rs
{
  if (rs.session == nil) return;
  [rs.session closeAllAt: GMMonotonicNow()];
  [_directory withdrawSessionNamed: rs.configuration.name];
  [_ports removePort: rs.midiPort];
  [rs.endpoint close];
  rs.session.delegate = nil;
  rs.session = nil;
  rs.endpoint = nil;
  rs.midiPort = -1;
}

- (void) shutdown
{
  for (GMRunningSession *rs in _running) [self stopSession: rs];
  [_directory withdrawAll];
  [_directory stopBrowsing];
  [_ports close];
  [_timer invalidate];
  _timer = nil;
  [_connection registerName: nil
             withNameServer: [NSMessagePortNameServer sharedInstance]];
  [_connection invalidate];
  _connection = nil;
}

#pragma mark - Timers

/* One timer for everything, set to the earliest deadline of any
 * participant, so an idle daemon does not wake up at all. */
- (void) reschedule
{
  NSTimeInterval next = 0, now;
  for (GMRunningSession *rs in _running)
    {
      NSTimeInterval d = [rs.session nextDeadline];
      if (d != 0 && (next == 0 || d < next)) next = d;
    }
  [_timer invalidate];
  _timer = nil;
  if (next == 0) return;
  now = GMMonotonicNow();
  _timer = [NSTimer scheduledTimerWithTimeInterval: MAX(next - now, 0.001)
                                            target: self
                                          selector: @selector(timerFired:)
                                          userInfo: nil
                                           repeats: NO];
}

- (void) timerFired: (NSTimer *)t
{
  NSTimeInterval now = GMMonotonicNow();
  _timer = nil;
  for (GMRunningSession *rs in [_running copy])
    [rs.session fireTimersAt: now];
  [self reschedule];
}

#pragma mark - Change notification

- (void) noteChanged
{
  if (_notePending) return;
  _notePending = YES;
  /* Coalesced: one clock sync round or a burst of joins is one change for
   * the pane. */
  [self performSelector: @selector(postChanged) withObject: nil afterDelay: 0.2];
}

- (void) postChanged
{
  _notePending = NO;
  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName: GMStatusDidChangeNotification object: GMDefaultsDomain
                userInfo: nil deliverImmediately: YES];
}

- (void) saveConfiguration
{
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  [ud setPersistentDomain: [_configuration domain] forName: GMDefaultsDomain];
  [ud synchronize];
}

#pragma mark - Routing

- (GMRunningSession *) runningSessionNamed: (NSString *)name
{
  for (GMRunningSession *rs in _running)
    if ([rs.configuration.name isEqualToString: name]) return rs;
  return nil;
}

- (void) session: (GMLocalSession *)session
  didReceiveMIDIMessages: (NSArray *)messages
                fromPeer: (GMPeerConnection *)peer
{
  for (GMRunningSession *rs in _running)
    if (rs.session == session)
      [_ports sendMessages: messages fromPort: rs.midiPort];
}

- (void) ports: (id<GMMIDIPorts>)ports
  didReceiveMessages: (NSArray *)messages
              onPort: (int)port
{
  for (GMRunningSession *rs in _running)
    if (rs.session != nil && rs.midiPort == port)
      [rs.session sendMIDIMessages: messages at: GMMonotonicNow()];
  [self reschedule];
}

- (BOOL) session: (GMLocalSession *)session
  directoryAllowsAddress: (NSData *)address
                    name: (NSString *)name
{
  for (GMDirectoryEntry *e in _configuration.directory)
    if (GMAddressHostsEqual(GMAddressFromNumericHost(e.host, e.port), address))
      return YES;
  return NO;
}

- (void) sessionParticipantsDidChange: (GMLocalSession *)session
{
  [self noteChanged];
}

- (void) serviceDirectoryDidChange: (GMServiceDirectory *)directory
{
  /* Connections to announced services are made whenever the service is
   * (again) resolvable and not connected, so they come back when the
   * other side restarts. */
  for (GMConnectionConfiguration *k in _configuration.connections)
    {
      GMDiscoveredService *svc;
      GMRunningSession *rs;
      NSData *addr;
      BOOL connected = NO;

      if (k.service == nil) continue;
      svc = [_directory serviceNamed: k.service];
      rs = [self runningSessionNamed: k.session];
      if ([svc.addresses count] == 0 || rs.session == nil) continue;
      addr = [svc.addresses objectAtIndex: 0];
      for (GMPeerConnection *p in rs.session.peers)
        if (GMAddressHostsEqual(p.controlAddress, addr)
          && GMAddressPort(p.controlAddress) == GMAddressPort(addr))
          connected = YES;
      if (!connected)
        {
          NSLog(@"gwmidid: %@: connecting to announced \"%@\" at %@", k.session,
            k.service, GMAddressDescription(addr));
          [rs.session inviteAddress: addr at: GMMonotonicNow()];
        }
    }
  [self reschedule];
  [self noteChanged];
}

#pragma mark - GMDaemonControl


- (bycopy NSDictionary *) daemonStatus
{
  NSMutableArray *sessions = [NSMutableArray array];
  NSMutableArray *dir = [NSMutableArray array];
  NSMutableArray *found = [NSMutableArray array];
  static NSString *roles[] = { @"initiator", @"responder" };

  for (GMRunningSession *rs in _running)
    {
      NSMutableDictionary *d = [[rs.configuration dictionary] mutableCopy];
      NSMutableArray *parts = [NSMutableArray array];
      for (GMPeerConnection *p in rs.session.peers)
        {
          [parts addObject: @{
            @"Identifier": [NSString stringWithFormat: @"%08x", p.token],
            @"Name": p.remoteName ? p.remoteName : @"",
            @"Address": GMAddressDescription(p.controlAddress),
            @"Role": roles[p.role],
            @"State": GMPeerStateName(p.state),
            @"LatencyMs": @(p.latency < 0 ? -1.0 : p.latency * 1000.0),
            @"PacketsSent": @(p.packetsSent),
            @"PacketsReceived": @(p.packetsReceived),
            @"SequenceGaps": @(p.sequenceGaps) }];
        }
      [d setObject: @(rs.session != nil) forKey: @"Running"];
      if (rs.midiPort >= 0)
        [d setObject: [_ports addressOfPort: rs.midiPort] forKey: @"MIDIPort"];
      if (rs.error) [d setObject: rs.error forKey: @"Error"];
      [d setObject: parts forKey: @"Participants"];
      [sessions addObject: d];
    }
  for (GMDirectoryEntry *e in _configuration.directory)
    [dir addObject: [e dictionary]];
  for (GMDiscoveredService *s in [_directory services])
    {
      NSMutableArray *hosts = [NSMutableArray array];
      for (NSData *a in s.addresses) [hosts addObject: GMAddressHost(a)];
      [found addObject: @{ @"Name": s.name,
        @"HostName": s.hostName ? s.hostName : @"",
        @"Addresses": hosts, @"Port": @(s.port) }];
    }
  return @{ @"PortLayer": [_ports portLayerDescription],
            GMKeySessions: sessions, GMKeyDirectory: dir,
            @"Discovered": found,
            @"Errors": _configuration.errors ? _configuration.errors : @[] };
}

/* Validates the would-be session list as a whole, so the same rules apply
 * as when reading the defaults. */
- (NSString *) applySessions: (NSArray *)configs
{
  GMConfiguration *trial;
  NSMutableDictionary *domain = [[_configuration domain] mutableCopy];
  NSMutableArray *list = [NSMutableArray array];
  for (GMSessionConfiguration *c in configs) [list addObject: [c dictionary]];
  [domain setObject: list forKey: GMKeySessions];
  trial = [GMConfiguration configurationWithDomain: domain
                                       defaultName: [self defaultSessionName]];
  if ([trial.sessions count] != [configs count])
    return [trial.errors lastObject];
  _configuration.sessions = trial.sessions;
  [self saveConfiguration];
  return nil;
}

- (bycopy NSString *) addSession: (bycopy NSDictionary *)configuration
{
  NSString *err = nil;
  GMSessionConfiguration *c = [GMSessionConfiguration
    configurationWithDictionary: configuration error: &err];
  if (c == nil) return err;
  err = [self applySessions: [_configuration.sessions arrayByAddingObject: c]];
  if (err) return err;
  [_running addObject: [self startSession: c]];
  [self noteChanged];
  return nil;
}

- (bycopy NSString *) updateSession: (bycopy NSString *)name
                  withConfiguration: (bycopy NSDictionary *)configuration
{
  NSString *err = nil;
  GMRunningSession *rs = [self runningSessionNamed: name];
  GMSessionConfiguration *c;
  NSMutableArray *list;
  NSUInteger i;

  if (rs == nil) return [NSString stringWithFormat: @"no session \"%@\"", name];
  c = [GMSessionConfiguration configurationWithDictionary: configuration
                                                   error: &err];
  if (c == nil) return err;
  list = [_configuration.sessions mutableCopy];
  i = [_running indexOfObject: rs];
  [list replaceObjectAtIndex: i withObject: c];
  if ((err = [self applySessions: list]) != nil) return err;

  /* Only a policy change can be applied to a running session; a new name
   * or port means new sockets, a new port and a new announcement. */
  if (rs.session != nil && c.enabled && [c.name isEqual: rs.configuration.name]
    && c.port == rs.configuration.port && c.announce == rs.configuration.announce)
    {
      rs.session.policy = c.policy;
      rs.configuration = c;
    }
  else
    {
      [self stopSession: rs];
      [_running replaceObjectAtIndex: i withObject: [self startSession: c]];
    }
  [self reschedule];
  [self noteChanged];
  return nil;
}

- (bycopy NSString *) removeSession: (bycopy NSString *)name
{
  GMRunningSession *rs = [self runningSessionNamed: name];
  NSMutableArray *list;
  if (rs == nil) return [NSString stringWithFormat: @"no session \"%@\"", name];
  list = [_configuration.sessions mutableCopy];
  [list removeObjectAtIndex: [_running indexOfObject: rs]];
  [self stopSession: rs];
  [_running removeObject: rs];
  _configuration.sessions = list;
  [self saveConfiguration];
  [self reschedule];
  [self noteChanged];
  return nil;
}

- (bycopy NSString *) setDirectoryEntries: (bycopy NSArray *)entries
{
  NSMutableArray *list = [NSMutableArray array];
  if (![entries isKindOfClass: [NSArray class]]) return @"not an array";
  for (id d in entries)
    {
      NSString *err = nil;
      GMDirectoryEntry *e = [GMDirectoryEntry entryWithDictionary: d error: &err];
      if (e == nil) return err;
      [list addObject: e];
    }
  _configuration.directory = list;
  [self saveConfiguration];
  [self noteChanged];
  return nil;
}

- (bycopy NSString *) connectSession: (bycopy NSString *)name
                                  to: (bycopy NSString *)target
{
  GMRunningSession *rs = [self runningSessionNamed: name];
  NSData *addr = nil;
  NSRange colon;

  if (rs.session == nil)
    return [NSString stringWithFormat: @"session \"%@\" is not running", name];
  for (GMDirectoryEntry *e in _configuration.directory)
    if ([e.name isEqualToString: target])
      addr = GMAddressFromNumericHost(e.host, e.port);
  if (addr == nil)
    {
      GMDiscoveredService *s = [_directory serviceNamed: target];
      if (s != nil && [s.addresses count] == 0)
        return [NSString stringWithFormat:
          @"\"%@\" is announced but not resolved yet", target];
      if (s != nil) addr = [s.addresses objectAtIndex: 0];
    }
  colon = [target rangeOfString: @":" options: NSBackwardsSearch];
  if (addr == nil && colon.location != NSNotFound)
    {
      NSString *host = [target substringToIndex: colon.location];
      int port = [[target substringFromIndex: colon.location + 1] intValue];
      if (port > 0 && port < 65535)
        addr = GMAddressFromNumericHost(host, (uint16_t)port);
    }
  if (addr == nil)
    return [NSString stringWithFormat: @"\"%@\" is neither a directory entry, "
      @"an announced session nor a numeric host:port", target];
  if (GMAddressHost(addr) && [GMAddressHost(addr) rangeOfString: @":"].location
      != NSNotFound)
    return @"IPv6 peers are not supported yet";
  [rs.session inviteAddress: addr at: GMMonotonicNow()];
  [self reschedule];
  return nil;
}

- (bycopy NSString *) disconnectParticipant: (bycopy NSString *)identifier
                                  inSession: (bycopy NSString *)name
{
  GMRunningSession *rs = [self runningSessionNamed: name];
  for (GMPeerConnection *p in rs.session.peers)
    {
      if ([[NSString stringWithFormat: @"%08x", p.token] isEqual: identifier])
        {
          [rs.session closePeer: p at: GMMonotonicNow()];
          [self reschedule];
          return nil;
        }
    }
  return [NSString stringWithFormat: @"no participant %@ in \"%@\"",
    identifier, name];
}

@end
