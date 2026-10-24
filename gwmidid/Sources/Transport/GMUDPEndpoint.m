/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "GMUDPEndpoint.h"
#import "GMDescriptorWatcher.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static int GMOpenUDP(uint16_t port, NSError **error)
{
  struct sockaddr_in a;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);

  if (fd < 0) goto fail;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0
    || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0)
    goto fail;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons(port);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) goto fail;
  return fd;

fail:
  if (error)
    {
      *error = [NSError errorWithDomain: NSPOSIXErrorDomain code: errno
        userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
          @"UDP port %u: %s", port, strerror(errno)]}];
    }
  if (fd >= 0) close(fd);
  return -1;
}

@implementation GMUDPEndpoint
{
  int _fd[2];                     /* control, data */
  GMDescriptorWatcher *_watcher[2];
  void (^_handler)(NSData *, NSData *, BOOL);
}

- (instancetype) initWithPort: (uint16_t)controlPort
                      handler: (void (^)(NSData *, NSData *, BOOL))handler
                        error: (NSError **)error
{
  if ((self = [super init]) == nil) return nil;
  _fd[0] = _fd[1] = -1;
  if (controlPort == 0 || controlPort == 65535)
    {
      if (error)
        *error = [NSError errorWithDomain: NSPOSIXErrorDomain code: EINVAL
          userInfo: @{NSLocalizedDescriptionKey:
            @"the control port must be between 1 and 65534"}];
      return nil;
    }
  _port = controlPort;
  _handler = [handler copy];
  if ((_fd[0] = GMOpenUDP(controlPort, error)) < 0
    || (_fd[1] = GMOpenUDP(controlPort + 1, error)) < 0)
    {
      [self close];
      return nil;
    }
  for (int i = 0; i < 2; i++)
    {
      __weak GMUDPEndpoint *weakSelf = self;
      BOOL control = (i == 0);
      _watcher[i] = [[GMDescriptorWatcher alloc] initWithDescriptor: _fd[i]
        handler: ^{ [weakSelf drain: control]; }];
    }
  return self;
}

/* Reads until the socket is empty: one wakeup may stand for many
 * datagrams, and leaving them would cost another trip through poll(). */
- (void) drain: (BOOL)control
{
  int fd = _fd[control ? 0 : 1];
  uint8_t buf[65536];

  while (fd >= 0)
    {
      struct sockaddr_storage from;
      socklen_t fl = sizeof from;
      ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
      if (n < 0)
        {
          if (errno == EINTR) continue;
          /* EAGAIN: drained.  ECONNREFUSED: an ICMP error for an earlier
           * send to a closed port; the peer's state machine notices that
           * nobody answers. */
          break;
        }
      _handler([NSData dataWithBytes: buf length: (NSUInteger)n],
        [NSData dataWithBytes: &from length: fl], control);
      fd = _fd[control ? 0 : 1];
    }
}

- (void) sendData: (NSData *)data to: (NSData *)address control: (BOOL)control
{
  int fd = _fd[control ? 0 : 1];
  if (fd < 0 || address == nil) return;
  if (sendto(fd, [data bytes], [data length], 0,
      (const struct sockaddr *)[address bytes], (socklen_t)[address length]) < 0)
    {
      NSLog(@"gwmidid: send on port %u failed: %s",
        _port + (control ? 0 : 1), strerror(errno));
    }
}

- (void) close
{
  for (int i = 0; i < 2; i++)
    {
      [_watcher[i] invalidate];
      _watcher[i] = nil;
      if (_fd[i] >= 0) close(_fd[i]);
      _fd[i] = -1;
    }
}

- (void) dealloc
{
  [self close];
}

@end
