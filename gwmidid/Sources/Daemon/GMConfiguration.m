/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMConfiguration.h"
#import "GMSocketAddress.h"

NSString * const GMDefaultsDomain = @"io.github.gershwin-desktop.gwmidid";
NSString * const GMStatusDidChangeNotification =
  @"io.github.gershwin-desktop.gwmidid.StatusDidChange";
NSString * const GMKeySessions = @"Sessions";
NSString * const GMKeyDirectory = @"Directory";
NSString * const GMKeyConnections = @"Connections";
NSString * const GMKeyName = @"Name";
NSString * const GMKeyPort = @"Port";
NSString * const GMKeyEnabled = @"Enabled";
NSString * const GMKeyPolicy = @"Policy";
NSString * const GMKeyAnnounce = @"Announce";
NSString * const GMKeyHost = @"Host";
NSString * const GMKeySession = @"Session";
NSString * const GMKeyService = @"Service";

/* mDNS labels are at most 63 bytes, ALSA port names 63 characters. */
#define GM_MAX_NAME_BYTES 63

/* Defaults written with the defaults tool arrive as strings; written by
 * the control interface as numbers.  Both are accepted, nothing else. */
static BOOL GMIntValue(id v, long *out)
{
  if ([v isKindOfClass: [NSNumber class]])
    {
      *out = [v longValue];
      return YES;
    }
  if ([v isKindOfClass: [NSString class]])
    {
      NSScanner *s = [NSScanner scannerWithString: v];
      long long l;
      if ([s scanLongLong: &l] && [s isAtEnd])
        {
          *out = (long)l;
          return YES;
        }
    }
  return NO;
}

static BOOL GMBoolValue(id v, BOOL dflt, BOOL *out)
{
  if (v == nil) { *out = dflt; return YES; }
  if ([v isKindOfClass: [NSNumber class]]) { *out = [v boolValue]; return YES; }
  if ([v isKindOfClass: [NSString class]])
    {
      NSString *l = [v lowercaseString];
      if ([l isEqual: @"yes"] || [l isEqual: @"true"] || [l isEqual: @"1"])
        { *out = YES; return YES; }
      if ([l isEqual: @"no"] || [l isEqual: @"false"] || [l isEqual: @"0"])
        { *out = NO; return YES; }
    }
  return NO;
}

static BOOL GMPortValue(id v, uint16_t *out, BOOL needsPair)
{
  long l;
  if (!GMIntValue(v, &l)) return NO;
  /* A session needs the port above it for data. */
  if (l < 1 || l > (needsPair ? 65534 : 65535)) return NO;
  *out = (uint16_t)l;
  return YES;
}

static NSString *GMValidName(id v)
{
  if (![v isKindOfClass: [NSString class]]) return nil;
  if ([v length] == 0) return nil;
  if (strlen([v UTF8String]) > GM_MAX_NAME_BYTES) return nil;
  return v;
}

@implementation GMSessionConfiguration

+ (instancetype) configurationWithDictionary: (NSDictionary *)d
                                       error: (NSString **)error
{
  GMSessionConfiguration *c = [self new];
  id policy = [d objectForKey: GMKeyPolicy];
  BOOL ok, b;
  uint16_t port;

  if (![d isKindOfClass: [NSDictionary class]])
    {
      if (error) *error = @"session entry is not a dictionary";
      return nil;
    }
  c.name = GMValidName([d objectForKey: GMKeyName]);
  if (c.name == nil)
    {
      if (error) *error = [NSString stringWithFormat:
        @"session name missing, empty or longer than %d bytes: %@",
        GM_MAX_NAME_BYTES, [d objectForKey: GMKeyName]];
      return nil;
    }
  if (!GMPortValue([d objectForKey: GMKeyPort], &port, YES))
    {
      if (error) *error = [NSString stringWithFormat:
        @"session \"%@\": port missing or not between 1 and 65534: %@",
        c.name, [d objectForKey: GMKeyPort]];
      return nil;
    }
  c.port = port;
  if (!GMBoolValue([d objectForKey: GMKeyEnabled], YES, &b))
    {
      if (error) *error = [NSString stringWithFormat:
        @"session \"%@\": Enabled is not a boolean", c.name];
      return nil;
    }
  c.enabled = b;
  if (!GMBoolValue([d objectForKey: GMKeyAnnounce], YES, &b))
    {
      if (error) *error = [NSString stringWithFormat:
        @"session \"%@\": Announce is not a boolean", c.name];
      return nil;
    }
  c.announce = b;
  c.policy = GMConnectionPolicyAnyone;
  if (policy != nil)
    {
      c.policy = [policy isKindOfClass: [NSString class]]
        ? GMConnectionPolicyFromString(policy, &ok) : GMConnectionPolicyNobody;
      if (![policy isKindOfClass: [NSString class]] || !ok)
        {
          if (error) *error = [NSString stringWithFormat:
            @"session \"%@\": policy must be anyone, directory or nobody: %@",
            c.name, policy];
          return nil;
        }
    }
  return c;
}

- (NSDictionary *) dictionary
{
  return @{ GMKeyName: _name, GMKeyPort: @(_port), GMKeyEnabled: @(_enabled),
            GMKeyAnnounce: @(_announce),
            GMKeyPolicy: GMConnectionPolicyString(_policy) };
}

- (id) copyWithZone: (NSZone *)zone
{
  return [[self class] configurationWithDictionary: [self dictionary] error: NULL];
}

@end

@implementation GMDirectoryEntry

+ (instancetype) entryWithDictionary: (NSDictionary *)d error: (NSString **)error
{
  GMDirectoryEntry *e = [self new];
  uint16_t port;
  if (![d isKindOfClass: [NSDictionary class]])
    {
      if (error) *error = @"directory entry is not a dictionary";
      return nil;
    }
  e.name = GMValidName([d objectForKey: GMKeyName]);
  e.host = [d objectForKey: GMKeyHost];
  if (e.name == nil)
    {
      if (error) *error = @"directory entry without a valid name";
      return nil;
    }
  /* Numeric only: resolving a name could block the daemon, and a name
   * that resolves differently later would silently change who may join. */
  if (![e.host isKindOfClass: [NSString class]]
    || GMAddressFromNumericHost(e.host, 1) == nil)
    {
      if (error) *error = [NSString stringWithFormat:
        @"directory entry \"%@\": Host must be a numeric address: %@",
        e.name, [d objectForKey: GMKeyHost]];
      return nil;
    }
  if (!GMPortValue([d objectForKey: GMKeyPort], &port, YES))
    {
      if (error) *error = [NSString stringWithFormat:
        @"directory entry \"%@\": invalid port %@", e.name,
        [d objectForKey: GMKeyPort]];
      return nil;
    }
  e.port = port;
  return e;
}

- (NSDictionary *) dictionary
{
  return @{ GMKeyName: _name, GMKeyHost: _host, GMKeyPort: @(_port) };
}

@end

@implementation GMConnectionConfiguration

+ (instancetype) connectionWithDictionary: (NSDictionary *)d error: (NSString **)error
{
  GMConnectionConfiguration *c = [self new];
  uint16_t port;
  if (![d isKindOfClass: [NSDictionary class]])
    {
      if (error) *error = @"connection entry is not a dictionary";
      return nil;
    }
  c.session = GMValidName([d objectForKey: GMKeySession]);
  if (c.session == nil)
    {
      if (error) *error = @"connection without a valid session name";
      return nil;
    }
  if ([d objectForKey: GMKeyService] != nil)
    {
      c.service = GMValidName([d objectForKey: GMKeyService]);
      if (c.service == nil || [d objectForKey: GMKeyHost] != nil)
        {
          if (error) *error = [NSString stringWithFormat:
            @"connection of \"%@\": Service must be a name, without Host",
            c.session];
          return nil;
        }
      return c;
    }
  c.host = [d objectForKey: GMKeyHost];
  if (![c.host isKindOfClass: [NSString class]]
    || GMAddressFromNumericHost(c.host, 1) == nil
    || !GMPortValue([d objectForKey: GMKeyPort], &port, YES))
    {
      if (error) *error = [NSString stringWithFormat:
        @"connection of \"%@\" needs a Service, or a numeric Host and a Port",
        c.session];
      return nil;
    }
  c.port = port;
  return c;
}

- (NSDictionary *) dictionary
{
  if (_service)
    return @{ GMKeySession: _session, GMKeyService: _service };
  return @{ GMKeySession: _session, GMKeyHost: _host, GMKeyPort: @(_port) };
}

@end

@implementation GMConfiguration

+ (instancetype) configurationWithDomain: (NSDictionary *)domain
                             defaultName: (NSString *)defaultName
{
  GMConfiguration *c = [self new];
  NSMutableArray *sessions = [NSMutableArray array];
  NSMutableArray *dir = [NSMutableArray array];
  NSMutableArray *conns = [NSMutableArray array];
  NSMutableArray *errors = [NSMutableArray array];
  NSMutableSet *names = [NSMutableSet set], *ports = [NSMutableSet set];
  id list = [domain objectForKey: GMKeySessions];

  if (list == nil)
    {
      list = @[ @{ GMKeyName: defaultName, GMKeyPort: @(GM_DEFAULT_PORT) } ];
    }
  if (![list isKindOfClass: [NSArray class]])
    {
      [errors addObject: @"Sessions is not an array"];
      list = @[];
    }
  for (id d in list)
    {
      NSString *err = nil;
      GMSessionConfiguration *s = [GMSessionConfiguration
        configurationWithDictionary: d error: &err];
      if (s == nil) { [errors addObject: err]; continue; }
      /* Each session owns its two ports; overlapping pairs could not both
       * be bound. */
      if ([names containsObject: s.name]
        || [ports containsObject: @(s.port)]
        || [ports containsObject: @(s.port + 1)]
        || [ports containsObject: @(s.port - 1)])
        {
          [errors addObject: [NSString stringWithFormat:
            @"session \"%@\" (port %u) clashes with an earlier session's "
            @"name or ports", s.name, s.port]];
          continue;
        }
      [names addObject: s.name];
      [ports addObject: @(s.port)];
      [sessions addObject: s];
    }

  list = [domain objectForKey: GMKeyDirectory];
  if (list != nil && ![list isKindOfClass: [NSArray class]])
    {
      [errors addObject: @"Directory is not an array"];
      list = nil;
    }
  for (id d in list)
    {
      NSString *err = nil;
      GMDirectoryEntry *e = [GMDirectoryEntry entryWithDictionary: d error: &err];
      if (e) [dir addObject: e]; else [errors addObject: err];
    }

  list = [domain objectForKey: GMKeyConnections];
  if (list != nil && ![list isKindOfClass: [NSArray class]])
    {
      [errors addObject: @"Connections is not an array"];
      list = nil;
    }
  for (id d in list)
    {
      NSString *err = nil;
      GMConnectionConfiguration *k =
        [GMConnectionConfiguration connectionWithDictionary: d error: &err];
      if (k) [conns addObject: k]; else [errors addObject: err];
    }

  c.sessions = sessions;
  c.directory = dir;
  c.connections = conns;
  c.errors = errors;
  return c;
}

- (NSDictionary *) domain
{
  NSMutableArray *s = [NSMutableArray array], *d = [NSMutableArray array],
    *k = [NSMutableArray array];
  for (GMSessionConfiguration *x in _sessions) [s addObject: [x dictionary]];
  for (GMDirectoryEntry *x in _directory) [d addObject: [x dictionary]];
  for (GMConnectionConfiguration *x in _connections) [k addObject: [x dictionary]];
  return @{ GMKeySessions: s, GMKeyDirectory: d, GMKeyConnections: k };
}

@end
