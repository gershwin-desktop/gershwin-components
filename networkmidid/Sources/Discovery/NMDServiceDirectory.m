/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "NMDServiceDirectory.h"
#include <sys/socket.h>
#include <netinet/in.h>

/* Protocol fact: the service type every RTP-MIDI peer browses for. */
static NSString * const NMDServiceType = @"_apple-midi._udp.";
static NSString * const NMDServiceDomain = @"local.";

@interface NMDDiscoveredService ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *hostName;
@property (nonatomic, copy) NSArray *addresses;
@property (nonatomic) uint16_t port;
@property (nonatomic, strong) NSNetService *netService;
@end

@implementation NMDDiscoveredService
- (NSString *) description
{
  return [NSString stringWithFormat: @"<%@ %@:%u, %lu addresses>", _name,
    _hostName, _port, (unsigned long)[_addresses count]];
}
@end

@interface NMDServiceDirectory () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation NMDServiceDirectory
{
  NSNetServiceBrowser *_browser;
  NSMutableDictionary *_found;       /* name -> NMDDiscoveredService */
  NSMutableDictionary *_published;   /* name -> NSNetService */
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _found = [NSMutableDictionary dictionary];
      _published = [NSMutableDictionary dictionary];
    }
  return self;
}

- (void) startBrowsing
{
  if (_browser != nil) return;
  _browser = [NSNetServiceBrowser new];
  [_browser setDelegate: self];
  [_browser searchForServicesOfType: NMDServiceType inDomain: NMDServiceDomain];
}

- (void) stopBrowsing
{
  [_browser stop];
  _browser = nil;
  for (NMDDiscoveredService *s in [_found allValues]) [s.netService stop];
  [_found removeAllObjects];
}

- (NSArray *) services
{
  return [[_found allValues] sortedArrayUsingComparator: ^(id a, id b) {
    return [[a name] compare: [b name]];
  }];
}

- (NMDDiscoveredService *) serviceNamed: (NSString *)name
{
  return [_found objectForKey: name];
}

- (void) announceSessionNamed: (NSString *)name port: (uint16_t)port
{
  NSNetService *s;
  [self withdrawSessionNamed: name];
  s = [[NSNetService alloc] initWithDomain: NMDServiceDomain
                                      type: NMDServiceType
                                      name: name
                                      port: port];
  [s setDelegate: self];
  [s publish];
  [_published setObject: s forKey: name];
}

- (void) withdrawSessionNamed: (NSString *)name
{
  NSNetService *s = [_published objectForKey: name];
  [s stop];
  [_published removeObjectForKey: name];
}

- (void) withdrawAll
{
  for (NSNetService *s in [_published allValues]) [s stop];
  [_published removeAllObjects];
}

- (void) changed
{
  [_delegate serviceDirectoryDidChange: self];
}

#pragma mark - Browsing

- (void) netServiceBrowser: (NSNetServiceBrowser *)b
            didFindService: (NSNetService *)service
                moreComing: (BOOL)more
{
  NMDDiscoveredService *d;

  /* Our own announcements come back too; they are not peers. */
  if ([_published objectForKey: [service name]] != nil) return;
  d = [NMDDiscoveredService new];
  d.name = [service name];
  d.netService = service;
  d.addresses = @[];
  [_found setObject: d forKey: d.name];
  [service setDelegate: self];
  [service resolveWithTimeout: 10.0];
  if (!more) [self changed];
}

- (void) netServiceBrowser: (NSNetServiceBrowser *)b
          didRemoveService: (NSNetService *)service
                moreComing: (BOOL)more
{
  NMDDiscoveredService *d = [_found objectForKey: [service name]];
  [d.netService stop];
  [_found removeObjectForKey: [service name]];
  if (!more) [self changed];
}

- (void) netServiceBrowser: (NSNetServiceBrowser *)b
              didNotSearch: (NSDictionary *)errorDict
{
  NSLog(@"networkmidid: mDNS browsing failed: %@", errorDict);
}

#pragma mark - Resolving

/* Called once per address as they arrive, so the list is rebuilt each
 * time.  Only IPv4 addresses are kept because our sockets are IPv4. */
- (void) netServiceDidResolveAddress: (NSNetService *)service
{
  NMDDiscoveredService *d = [_found objectForKey: [service name]];
  NSMutableArray *v4 = [NSMutableArray array];
  uint16_t port = 0;

  if (d == nil || d.netService != service) return;
  for (NSData *a in [service addresses])
    {
      const struct sockaddr *sa = [a bytes];
      if ([a length] >= sizeof(struct sockaddr_in) && sa->sa_family == AF_INET)
        {
          [v4 addObject: a];
          port = ntohs(((const struct sockaddr_in *)sa)->sin_port);
        }
    }
  d.addresses = v4;
  d.hostName = [service hostName];
  d.port = port ? port : (uint16_t)[service port];
  [self changed];
}

- (void) netService: (NSNetService *)service didNotResolve: (NSDictionary *)err
{
  NSLog(@"networkmidid: could not resolve \"%@\": %@", [service name], err);
}

#pragma mark - Publishing

- (void) netServiceDidPublish: (NSNetService *)service
{
  NSLog(@"networkmidid: announced \"%@\" on port %ld", [service name],
    (long)[service port]);
}

- (void) netService: (NSNetService *)service didNotPublish: (NSDictionary *)err
{
  NSLog(@"networkmidid: could not announce \"%@\": %@", [service name], err);
}

@end
