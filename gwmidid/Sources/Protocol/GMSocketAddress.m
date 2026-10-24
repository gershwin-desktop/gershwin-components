/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMSocketAddress.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>

static int GMFamily(NSData *a)
{
  if ([a length] < sizeof(sa_family_t) + 1) return -1;
  return ((const struct sockaddr *)[a bytes])->sa_family;
}

uint16_t GMAddressPort(NSData *a)
{
  if (GMFamily(a) == AF_INET && [a length] >= sizeof(struct sockaddr_in))
    return ntohs(((const struct sockaddr_in *)[a bytes])->sin_port);
  if (GMFamily(a) == AF_INET6 && [a length] >= sizeof(struct sockaddr_in6))
    return ntohs(((const struct sockaddr_in6 *)[a bytes])->sin6_port);
  return 0;
}

NSData *GMAddressWithPort(NSData *a, uint16_t port)
{
  NSMutableData *m = [a mutableCopy];
  if (GMFamily(a) == AF_INET && [a length] >= sizeof(struct sockaddr_in))
    ((struct sockaddr_in *)[m mutableBytes])->sin_port = htons(port);
  else if (GMFamily(a) == AF_INET6 && [a length] >= sizeof(struct sockaddr_in6))
    ((struct sockaddr_in6 *)[m mutableBytes])->sin6_port = htons(port);
  else
    return nil;
  return m;
}

NSString *GMAddressHost(NSData *a)
{
  char buf[INET6_ADDRSTRLEN];
  if (GMFamily(a) == AF_INET && [a length] >= sizeof(struct sockaddr_in))
    inet_ntop(AF_INET, &((const struct sockaddr_in *)[a bytes])->sin_addr,
      buf, sizeof buf);
  else if (GMFamily(a) == AF_INET6 && [a length] >= sizeof(struct sockaddr_in6))
    inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)[a bytes])->sin6_addr,
      buf, sizeof buf);
  else
    return nil;
  return [NSString stringWithUTF8String: buf];
}

NSString *GMAddressDescription(NSData *a)
{
  NSString *h = GMAddressHost(a);
  if (h == nil) return @"(invalid address)";
  if (GMFamily(a) == AF_INET6)
    return [NSString stringWithFormat: @"[%@]:%u", h, GMAddressPort(a)];
  return [NSString stringWithFormat: @"%@:%u", h, GMAddressPort(a)];
}

BOOL GMAddressHostsEqual(NSData *a, NSData *b)
{
  NSString *ha = GMAddressHost(a);
  return ha != nil && [ha isEqualToString: GMAddressHost(b)];
}

NSData *GMAddressFromNumericHost(NSString *host, uint16_t port)
{
  struct sockaddr_in in4;
  struct sockaddr_in6 in6;
  const char *h = [host UTF8String];

  if (h == NULL) return nil;
  memset(&in4, 0, sizeof in4);
  if (inet_pton(AF_INET, h, &in4.sin_addr) == 1)
    {
      in4.sin_family = AF_INET;
      in4.sin_port = htons(port);
#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \
  || defined(__DragonFly__)
      in4.sin_len = sizeof in4;
#endif
      return [NSData dataWithBytes: &in4 length: sizeof in4];
    }
  memset(&in6, 0, sizeof in6);
  if (inet_pton(AF_INET6, h, &in6.sin6_addr) == 1)
    {
      in6.sin6_family = AF_INET6;
      in6.sin6_port = htons(port);
#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \
  || defined(__DragonFly__)
      in6.sin6_len = sizeof in6;
#endif
      return [NSData dataWithBytes: &in6 length: sizeof in6];
    }
  return nil;
}
