/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/*
 * networkmidid: the per-user network MIDI daemon of the Gershwin desktop.
 * Shares MIDI between applications on this computer and other computers
 * and devices on the network using RTP-MIDI (RFC 6295 and its session
 * protocol).  Each configured session is announced on the local network
 * and appears as one MIDI port applications can connect to.
 */
#import <Foundation/Foundation.h>
#import "NMDDaemon.h"
#import "NMDDescriptorWatcher.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static int NMDSignalPipe[2] = { -1, -1 };

/* Async-signal-safe: the run loop picks the byte up and shuts down in
 * ordinary code, where sending BY and talking to mDNS is allowed. */
static void NMDSignalHandler(int sig)
{
  int saved = errno;
  unsigned char c = (unsigned char)sig;
  (void)!write(NMDSignalPipe[1], &c, 1);
  errno = saved;
}

int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      NMDDaemon *daemon = [NMDDaemon new];
      NSString *error = nil;
      NMDDescriptorWatcher *signals;
      struct sigaction sa;

      if (pipe(NMDSignalPipe) < 0
        || fcntl(NMDSignalPipe[0], F_SETFD, FD_CLOEXEC) < 0
        || fcntl(NMDSignalPipe[1], F_SETFD, FD_CLOEXEC) < 0
        || fcntl(NMDSignalPipe[1], F_SETFL, O_NONBLOCK) < 0)
        {
          fprintf(stderr, "networkmidid: pipe: %s\n", strerror(errno));
          return 1;
        }
      memset(&sa, 0, sizeof sa);
      sa.sa_handler = NMDSignalHandler;
      sigemptyset(&sa.sa_mask);
      sigaction(SIGTERM, &sa, NULL);
      sigaction(SIGINT, &sa, NULL);
      sigaction(SIGHUP, &sa, NULL);
      /* A peer that vanished makes sends fail with errors, not signals,
       * but a closed control connection must not kill the daemon. */
      signal(SIGPIPE, SIG_IGN);

      if (![daemon startWithError: &error])
        {
          fprintf(stderr, "networkmidid: %s\n", [error UTF8String]);
          return 1;
        }
      signals = [[NMDDescriptorWatcher alloc]
        initWithDescriptor: NMDSignalPipe[0] handler: ^{
          unsigned char c = 0;
          (void)!read(NMDSignalPipe[0], &c, 1);
          NSLog(@"networkmidid: signal %d, ending all sessions", c);
          [daemon shutdown];
          exit(0);
        }];
      NSLog(@"networkmidid: running");
      [[NSRunLoop currentRunLoop] run];
      [signals invalidate];
    }
  return 0;
}
