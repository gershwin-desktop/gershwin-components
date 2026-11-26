/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCWSDEventListener.h"
#import "SCWSDClient.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>

/* A notification is a few KB; anything far larger is not one */
static const NSUInteger SCMaximumRequest = 256 * 1024;

@implementation SCWSDEventListener
{
  NSString *_host;
  void (^_handler)(SCWSDScanEvent *);
  int _socket;
  unsigned short _port;
  NSString *_localAddress;
  volatile BOOL _stopped;
}

- (instancetype) initWithPrinterHost: (NSString *)host
                             handler: (void (^)(SCWSDScanEvent *))handler
{
  self = [super init];
  if (self)
    {
      _host = [host copy];
      _handler = [handler copy];
      _socket = -1;
    }
  return self;
}

- (void) dealloc
{
  [self stop];
}

/* The address of this computer on the way to the printer; connect() sends nothing for UDP */
- (NSString *) addressTowardsPrinter
{
  struct sockaddr_in to, me;
  socklen_t length = sizeof(me);
  char ip[INET_ADDRSTRLEN];
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  NSString *address = nil;

  memset(&to, 0, sizeof(to));
  to.sin_family = AF_INET;
  to.sin_port = htons(80);
  if (s >= 0 && inet_pton(AF_INET, [_host UTF8String], &to.sin_addr) == 1
      && connect(s, (struct sockaddr *)&to, sizeof(to)) == 0
      && getsockname(s, (struct sockaddr *)&me, &length) == 0
      && inet_ntop(AF_INET, &me.sin_addr, ip, sizeof(ip)) != NULL)
    {
      address = [NSString stringWithUTF8String: ip];
    }
  if (s >= 0)
    {
      close(s);
    }
  return address;
}

- (BOOL) start
{
  struct sockaddr_in addr;
  socklen_t length = sizeof(addr);
  int yes = 1;

  _localAddress = [self addressTowardsPrinter];
  if (_localAddress == nil)
    {
      return NO;
    }
  _socket = socket(AF_INET, SOCK_STREAM, 0);
  if (_socket < 0)
    {
      return NO;
    }
  setsockopt(_socket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  inet_pton(AF_INET, [_localAddress UTF8String], &addr.sin_addr);
  addr.sin_port = 0;
  if (bind(_socket, (struct sockaddr *)&addr, sizeof(addr)) != 0
      || listen(_socket, 4) != 0
      || getsockname(_socket, (struct sockaddr *)&addr, &length) != 0)
    {
      close(_socket);
      _socket = -1;
      return NO;
    }
  _port = ntohs(addr.sin_port);
  _stopped = NO;
  [NSThread detachNewThreadSelector: @selector(serve:) toTarget: self withObject: nil];
  return YES;
}

- (void) stop
{
  _stopped = YES;
  if (_socket >= 0)
    {
      close(_socket);
      _socket = -1;
    }
}

- (NSString *) notifyURL
{
  return [NSString stringWithFormat: @"http://%@:%u/scanner-events", _localAddress, _port];
}

/* Reads one HTTP request; returns its body, nil when it is not a complete one */
static NSData *
SCReadRequest(int c)
{
  NSMutableData *data = [NSMutableData data];
  NSData *separator = [@"\r\n\r\n" dataUsingEncoding: NSASCIIStringEncoding];
  NSUInteger headerEnd = NSNotFound, contentLength = 0;
  char buffer[8192];

  while ([data length] < SCMaximumRequest)
    {
      struct timeval tv = {5, 0};
      fd_set fds;
      ssize_t n;

      FD_ZERO(&fds);
      FD_SET(c, &fds);
      if (select(c + 1, &fds, NULL, NULL, &tv) <= 0)
        {
          return nil;
        }
      n = recv(c, buffer, sizeof(buffer), 0);
      if (n <= 0)
        {
          return nil;
        }
      [data appendBytes: buffer length: n];
      if (headerEnd == NSNotFound)
        {
          NSRange r = [data rangeOfData: separator options: 0
                                  range: NSMakeRange(0, [data length])];
          NSString *headers;
          NSRange cl;

          if (r.location == NSNotFound)
            {
              continue;
            }
          headerEnd = NSMaxRange(r);
          headers = [[[NSString alloc] initWithData: [data subdataWithRange:
                                                        NSMakeRange(0, r.location)]
                                           encoding: NSISOLatin1StringEncoding]
                      lowercaseString];
          cl = [headers rangeOfString: @"content-length:"];
          if (cl.location == NSNotFound)
            {
              return nil;
            }
          contentLength = [[headers substringFromIndex: NSMaxRange(cl)] integerValue];
        }
      if (headerEnd != NSNotFound && [data length] >= headerEnd + contentLength)
        {
          return [data subdataWithRange: NSMakeRange(headerEnd, contentLength)];
        }
    }
  return nil;
}

- (void) serve: (id)unused
{
  int listening = _socket;

  while (!_stopped)
    {
      @autoreleasepool
        {
          struct sockaddr_in from;
          socklen_t length = sizeof(from);
          char ip[INET_ADDRSTRLEN];
          const char *reply = "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n"
                              "Connection: close\r\n\r\n";
          struct timeval tv = {1, 0};
          fd_set fds;
          NSData *body;
          SCWSDScanEvent *event;
          int c;

          FD_ZERO(&fds);
          FD_SET(listening, &fds);
          /* Wakes up now and then, so -stop is noticed */
          if (select(listening + 1, &fds, NULL, NULL, &tv) <= 0)
            {
              continue;
            }
          c = accept(listening, (struct sockaddr *)&from, &length);
          if (c < 0)
            {
              continue;
            }
          inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
          if (![[NSString stringWithUTF8String: ip] isEqualToString: _host])
            {
              close(c);
              continue;
            }
          body = SCReadRequest(c);
          send(c, reply, strlen(reply), 0);
          close(c);
          event = body ? [SCWSDClient scanEventFromXML:
                            [[NSString alloc] initWithData: body
                                                  encoding: NSUTF8StringEncoding]]
                       : nil;
          if (event != nil && !_stopped)
            {
              [self performSelectorOnMainThread: @selector(deliver:) withObject: event
                                  waitUntilDone: NO];
            }
        }
    }
}

- (void) deliver: (SCWSDScanEvent *)event
{
  if (!_stopped)
    {
      _handler(event);
    }
}

@end
