/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCHTTPPost.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>

/* Sizes beyond any scanned page; guards against garbage taken for a length */
static const unsigned long long SCMaximumBody = 1024ULL * 1024 * 1024;

static NSError *
SCHTTPError(NSString *reason)
{
  return [NSError errorWithDomain: @"SCHTTPPost" code: 1 userInfo: @{
    NSLocalizedDescriptionKey: reason
  }];
}

/*
 * End of the line starting at start: the index of its terminator and, in
 * *next, where the following line begins. A bare LF ends a line too
 * (RFC 9112 2.2). NSNotFound while the line is incomplete.
 */
static NSUInteger
SCLineEnd(const uint8_t *bytes, NSUInteger length, NSUInteger start, NSUInteger *next)
{
  NSUInteger i;

  for (i = start; i < length; i++)
    {
      if (bytes[i] == '\n')
        {
          *next = i + 1;
          return (i > start && bytes[i - 1] == '\r') ? i - 1 : i;
        }
    }
  return NSNotFound;
}

@implementation SCHTTPResponse

+ (SCHTTPResponse *) responseFromData: (NSData *)raw
                          endOfStream: (BOOL)eof
                            malformed: (BOOL *)malformed
{
  const uint8_t *bytes = [raw bytes];
  NSUInteger length = [raw length];
  NSUInteger pos = 0;

  *malformed = NO;
  /* 1xx answers (100 Continue) come before the final one and carry no body */
  for (;;)
    {
      NSMutableDictionary *headers = [NSMutableDictionary dictionary];
      NSUInteger next, end = SCLineEnd(bytes, length, pos, &next);
      NSString *line, *te, *cl;
      NSArray *status;
      NSInteger code;
      SCHTTPResponse *r;

      if (end == NSNotFound)
        {
          *malformed = eof;
          return nil;
        }
      line = [[NSString alloc] initWithBytes: bytes + pos length: end - pos
                                    encoding: NSISOLatin1StringEncoding];
      status = [line componentsSeparatedByString: @" "];
      if ([status count] < 2 || ![status[0] hasPrefix: @"HTTP/1."]
          || [status[1] length] != 3 || (code = [status[1] integerValue]) < 100)
        {
          *malformed = YES;
          return nil;
        }
      pos = next;
      for (;;)
        {
          NSRange colon;
          NSString *name, *value, *old;

          end = SCLineEnd(bytes, length, pos, &next);
          if (end == NSNotFound)
            {
              *malformed = eof;
              return nil;
            }
          if (end == pos)
            {
              pos = next;
              break;
            }
          line = [[NSString alloc] initWithBytes: bytes + pos length: end - pos
                                        encoding: NSISOLatin1StringEncoding];
          pos = next;
          colon = [line rangeOfString: @":"];
          if (colon.location == NSNotFound || colon.location == 0)
            {
              *malformed = YES;
              return nil;
            }
          name = [[line substringToIndex: colon.location] lowercaseString];
          value = [[line substringFromIndex: NSMaxRange(colon)]
                    stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          old = headers[name];
          headers[name] = old ? [NSString stringWithFormat: @"%@, %@", old, value] : value;
        }
      if (code < 200)
        {
          continue;
        }

      r = [SCHTTPResponse new];
      [r setStatusCode: code];
      [r setHeaders: headers];
      te = [headers[@"transfer-encoding"] lowercaseString];
      cl = headers[@"content-length"];
      if (code == 204 || code == 304)
        {
          [r setBody: [NSData data]];
        }
      else if (te != nil)
        {
          /* Transfer-Encoding wins over Content-Length (RFC 9112 6.3) */
          NSString *last = [[[te componentsSeparatedByString: @","] lastObject]
                             stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];

          if ([last isEqualToString: @"chunked"])
            {
              NSUInteger used;
              NSData *rest = [raw subdataWithRange: NSMakeRange(pos, length - pos)];
              NSData *body = [SCHTTPPost dataByDecodingChunks: rest consumed: &used
                                                    malformed: malformed];

              if (body == nil)
                {
                  *malformed = *malformed || eof;
                  return nil;
                }
              [r setBody: body];
            }
          else
            {
              if (!eof)
                {
                  return nil;
                }
              [r setBody: [raw subdataWithRange: NSMakeRange(pos, length - pos)]];
            }
        }
      else if (cl != nil)
        {
          unsigned long long n = 0;
          NSUInteger i;

          /* Content-Length is 1*DIGIT (RFC 9110 8.6) */
          for (i = 0; i < [cl length] && n <= SCMaximumBody; i++)
            {
              unichar c = [cl characterAtIndex: i];

              if (c < '0' || c > '9')
                {
                  break;
                }
              n = n * 10 + (c - '0');
            }
          if ([cl length] == 0 || i < [cl length] || n > SCMaximumBody)
            {
              *malformed = YES;
              return nil;
            }
          if (length - pos < n)
            {
              *malformed = eof;
              return nil;
            }
          [r setBody: [raw subdataWithRange: NSMakeRange(pos, (NSUInteger)n)]];
        }
      else
        {
          if (!eof)
            {
              return nil;
            }
          [r setBody: [raw subdataWithRange: NSMakeRange(pos, length - pos)]];
        }
      return r;
    }
}

@end

@implementation SCHTTPPost

+ (NSData *) dataByDecodingChunks: (NSData *)data
                         consumed: (NSUInteger *)consumed
                        malformed: (BOOL *)malformed
{
  const uint8_t *bytes = [data bytes];
  NSUInteger length = [data length];
  NSUInteger pos = 0;
  NSMutableData *out = [NSMutableData data];

  *malformed = NO;
  for (;;)
    {
      NSUInteger next, end = SCLineEnd(bytes, length, pos, &next);
      unsigned long long size = 0;
      NSUInteger i, digits = 0;

      if (end == NSNotFound)
        {
          return nil;
        }
      /* chunk-size, then optional chunk extensions after ";", which are ignored */
      for (i = pos; i < end; i++)
        {
          uint8_t c = bytes[i];
          int v;

          if (c >= '0' && c <= '9')
            {
              v = c - '0';
            }
          else if (c >= 'a' && c <= 'f')
            {
              v = c - 'a' + 10;
            }
          else if (c >= 'A' && c <= 'F')
            {
              v = c - 'A' + 10;
            }
          else
            {
              break;
            }
          size = size * 16 + v;
          if (++digits > 16 || size > SCMaximumBody)
            {
              *malformed = YES;
              return nil;
            }
        }
      while (i < end && (bytes[i] == ' ' || bytes[i] == '\t'))
        {
          i++;
        }
      if (digits == 0 || (i < end && bytes[i] != ';'))
        {
          *malformed = YES;
          return nil;
        }
      pos = next;

      if (size == 0)
        {
          /* The trailer section: fields up to an empty line, all ignored */
          for (;;)
            {
              BOOL empty;

              end = SCLineEnd(bytes, length, pos, &next);
              if (end == NSNotFound)
                {
                  return nil;
                }
              empty = (end == pos);
              pos = next;
              if (empty)
                {
                  break;
                }
            }
          *consumed = pos;
          return out;
        }

      if (length - pos < size)
        {
          return nil;
        }
      [out appendBytes: bytes + pos length: (NSUInteger)size];
      pos += (NSUInteger)size;
      /* Each chunk's data ends with a line break of its own */
      if (pos < length && bytes[pos] == '\r')
        {
          if (pos + 1 >= length)
            {
              return nil;
            }
          if (bytes[pos + 1] != '\n')
            {
              *malformed = YES;
              return nil;
            }
          pos += 2;
        }
      else if (pos < length && bytes[pos] == '\n')
        {
          pos += 1;
        }
      else if (pos >= length)
        {
          return nil;
        }
      else
        {
          *malformed = YES;
          return nil;
        }
    }
}

/* Waits for fd to become ready; NO on timeout or error */
static BOOL
SCWait(int fd, short events, NSTimeInterval timeout)
{
  struct pollfd p = { fd, events, 0 };
  int r;

  do
    {
      r = poll(&p, 1, (int)(timeout * 1000));
    }
  while (r < 0 && errno == EINTR);
  return r == 1 && (p.revents & (events | POLLHUP)) != 0;
}

static int
SCConnect(NSString *host, NSString *port, NSTimeInterval timeout, NSError **error)
{
  struct addrinfo hints, *list = NULL, *a;
  int fd = -1;
  int r;

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  r = getaddrinfo([host UTF8String], [port UTF8String], &hints, &list);
  if (r != 0)
    {
      *error = SCHTTPError([NSString stringWithFormat: @"%@ was not found (%s).",
                                     host, gai_strerror(r)]);
      return -1;
    }
  for (a = list; a != NULL && fd < 0; a = a->ai_next)
    {
      int soError = 0;
      socklen_t len = sizeof(soError);

      fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
      if (fd < 0)
        {
          continue;
        }
      /* Non-blocking, so that a printer that is switched off costs only the timeout */
      fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
      {
        int yes = 1;

        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
      }
#endif
      if (connect(fd, a->ai_addr, a->ai_addrlen) != 0
          && (errno != EINPROGRESS || !SCWait(fd, POLLOUT, timeout)
              || getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) != 0
              || soError != 0))
        {
          close(fd);
          fd = -1;
        }
    }
  freeaddrinfo(list);
  if (fd < 0)
    {
      *error = SCHTTPError([NSString stringWithFormat: @"%@ did not accept the connection.",
                                     host]);
    }
  return fd;
}

+ (SCHTTPResponse *) post: (NSData *)body
              contentType: (NSString *)contentType
                       to: (NSURL *)url
                  timeout: (NSTimeInterval)timeout
                    error: (NSError **)error
{
  NSString *host = [url host];
  NSString *port = [url port] ? [[url port] stringValue] : @"80";
  NSString *target = [url path];
  NSString *hostField;
  NSMutableData *request, *raw = [NSMutableData data];
  NSError *failure = nil;
  SCHTTPResponse *response = nil;
  NSUInteger sent = 0;
  BOOL malformed = NO;
  int fd;

  if (![[[url scheme] lowercaseString] isEqualToString: @"http"] || [host length] == 0)
    {
      failure = SCHTTPError([NSString stringWithFormat: @"%@ is not an http address.", url]);
      goto done;
    }
  if ([target length] == 0)
    {
      target = @"/";
    }
  if ([url query])
    {
      target = [NSString stringWithFormat: @"%@?%@", target, [url query]];
    }
  /* An IPv6 literal goes into brackets in the Host field (RFC 9110 7.2) */
  hostField = [host rangeOfString: @":"].location != NSNotFound
    ? [NSString stringWithFormat: @"[%@]", host] : host;
  if ([url port])
    {
      hostField = [NSString stringWithFormat: @"%@:%@", hostField, port];
    }
  request = [[[NSString stringWithFormat:
                @"POST %@ HTTP/1.1\r\nHost: %@\r\nContent-Type: %@\r\n"
                @"Content-Length: %lu\r\nConnection: close\r\n\r\n",
                target, hostField, contentType, (unsigned long)[body length]]
               dataUsingEncoding: NSISOLatin1StringEncoding] mutableCopy];
  [request appendData: body];

  fd = SCConnect(host, port, timeout, &failure);
  if (fd < 0)
    {
      goto done;
    }
  while (sent < [request length])
    {
#ifdef MSG_NOSIGNAL
      ssize_t n = send(fd, (const char *)[request bytes] + sent, [request length] - sent,
                       MSG_NOSIGNAL);
#else
      ssize_t n = send(fd, (const char *)[request bytes] + sent, [request length] - sent, 0);
#endif

      if (n > 0)
        {
          sent += n;
        }
      else if (n < 0 && errno == EINTR)
        {
          continue;
        }
      else if (n < 0 && errno == EAGAIN && SCWait(fd, POLLOUT, timeout))
        {
          continue;
        }
      else
        {
          failure = SCHTTPError(@"the request could not be sent.");
          break;
        }
    }
  /* The timeout is for silence, as with NSURLRequest: a long scan keeps sending */
  while (failure == nil && response == nil)
    {
      uint8_t buffer[16384];
      ssize_t n;

      if (!SCWait(fd, POLLIN, timeout))
        {
          failure = SCHTTPError(@"the printer stopped answering.");
          break;
        }
      n = recv(fd, buffer, sizeof(buffer), 0);
      if (n < 0 && (errno == EINTR || errno == EAGAIN))
        {
          continue;
        }
      if (n < 0)
        {
          failure = SCHTTPError([NSString stringWithFormat: @"the connection broke (%s).",
                                          strerror(errno)]);
          break;
        }
      [raw appendBytes: buffer length: n];
      response = [SCHTTPResponse responseFromData: raw endOfStream: n == 0
                                        malformed: &malformed];
      if (malformed)
        {
          failure = SCHTTPError(n == 0 ? @"the answer ended too early."
                                       : @"the answer was not valid HTTP.");
        }
    }
  close(fd);

done:
  if (failure != nil && error)
    {
      *error = failure;
    }
  return failure ? nil : response;
}

@end
