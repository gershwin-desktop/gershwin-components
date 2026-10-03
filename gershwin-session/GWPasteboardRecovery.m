/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
#import "GWPasteboardRecovery.h"
#import <Foundation/NSPortNameServer.h>
#import <Foundation/NSConnection.h>
#import <Foundation/NSDistantObject.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>

/* Attempts a Distributed Objects round trip to `name` and reports the
 * result through `okFd` (one byte: 1 = answered, 0 = did not).  Runs in
 * a forked child so a peer that is truly wedged outside its run loop
 * (the exact failure mode this guards against) can never block the
 * caller - killing this child on a timeout is always safe, since it
 * touches nothing but this one round trip.
 */
static void
checkInChild(NSString *name, int okFd)
{
  unsigned char ok = 0;

  @autoreleasepool
    {
      /* The same call NSPasteboard.m's -_pbs uses to reach gpbs in the
       * first place (Source/NSPasteboard.m, ~line 1985).  It builds its
       * own receive port internally, unlike a bare
       * -connectionWithReceivePort:sendPort: with a nil receive port,
       * which never gets a reply channel and would misreport a healthy
       * server as unresponsive too.  This call's own wait is not bounded
       * here - the parent enforces the timeout from outside by killing
       * this whole child, which is safe because a stuck round trip here
       * touches nothing but this one throwaway process. */
      id proxy = [NSConnection rootProxyForConnectionWithRegisteredName: name
								     host: @""];
      if (proxy != nil)
	{
	  ok = 1;
	}
    }
  write(okFd, &ok, 1);
  _exit(0);
}

BOOL
GWEnsureResponsivePasteboardServer(NSString *name,
  const char *killIfStuckComm, NSTimeInterval timeout)
{
  NSPort *port = [[NSMessagePortNameServer sharedInstance] portForName: name];
  int fds[2];
  pid_t child;
  unsigned char answered = 0;
  struct timespec deadline, now;

  if (port == nil)
    {
      /* Nothing registered at all - the first app that touches the
       * pasteboard will auto-launch a fresh server; there is nothing
       * stuck to clean up. */
      return YES;
    }

  if (pipe(fds) != 0)
    {
      /* Fail hard rather than guess: if we cannot even check, we must
       * not silently assume the server is fine. */
      NSLog(@"GWEnsureResponsivePasteboardServer: pipe() failed (%s)",
	strerror(errno));
      return YES;
    }

  child = fork();
  if (child < 0)
    {
      NSLog(@"GWEnsureResponsivePasteboardServer: fork() failed (%s)",
	strerror(errno));
      close(fds[0]);
      close(fds[1]);
      return YES;
    }

  if (child == 0)
    {
      /* Child: never touch anything except this one round trip and the
       * pipe back to the parent. */
      close(fds[0]);
      checkInChild(name, fds[1]);
      _exit(0); /* unreachable, checkInChild() calls _exit() */
    }

  close(fds[1]);

  /* Give the child a little longer than its own DO timeout, so a slow
   * but genuinely answering server is not mistaken for a stuck one; if
   * it still has not reported back, its own timeouts must themselves be
   * wedged (or the process is not turning its run loop at all, which is
   * exactly the bug this guards against), so we stop waiting and treat
   * it as unresponsive. */
  clock_gettime(CLOCK_MONOTONIC, &deadline);
  deadline.tv_sec += (time_t)(timeout + 2.0);

  for (;;)
    {
      fd_set rfds;
      struct timeval tv;
      double remain;

      clock_gettime(CLOCK_MONOTONIC, &now);
      remain = (double)(deadline.tv_sec - now.tv_sec)
	+ (double)(deadline.tv_nsec - now.tv_nsec) / 1e9;
      if (remain <= 0.0)
	{
	  break;
	}

      FD_ZERO(&rfds);
      FD_SET(fds[0], &rfds);
      tv.tv_sec = (long)remain;
      tv.tv_usec = (long)((remain - (double)tv.tv_sec) * 1e6);
      if (select(fds[0] + 1, &rfds, NULL, NULL, &tv) > 0)
	{
	  if (read(fds[0], &answered, 1) != 1)
	    {
	      answered = 0;
	    }
	  break;
	}
      break; /* select() timed out or errored - stop waiting either way */
    }

  close(fds[0]);

  /* The child may still be running (e.g. blocked inside -rootProxy
   * despite the timeouts we set, if the peer never even completes the
   * connection handshake); reap it unconditionally so we never leak a
   * zombie into the session supervisor's own process table. */
  kill(child, SIGKILL);
  waitpid(child, NULL, 0);

  if (answered)
    {
      return YES;
    }

  NSLog(@"GWEnsureResponsivePasteboardServer: %@ is registered but did not"
    @" answer within %.1fs; killing every '%s' process owned by this user"
    @" so a fresh one can register.", name, timeout, killIfStuckComm);

  {
    char cmd[128];
    char line[256];
    FILE *fp;

    /* Match by command name scoped to our own uid only, the same
     * pattern LoginWindow.m already uses for its end-of-session cleanup
     * of these same detached daemons (gpbs, gdnc) - never a bare system
     * wide pkill, and never another user's process. */
    snprintf(cmd, sizeof(cmd), "ps -u %d -o pid= -o comm=", (int)getuid());
    fp = popen(cmd, "r");
    if (fp != NULL)
      {
	while (fgets(line, sizeof(line), fp) != NULL)
	  {
	    int pid = 0;
	    char comm[256];

	    if (sscanf(line, "%d %255s", &pid, comm) == 2
	      && strcmp(comm, killIfStuckComm) == 0)
	      {
		NSLog(@"GWEnsureResponsivePasteboardServer: killing stale"
		  @" %s (pid %d)", killIfStuckComm, pid);
		kill((pid_t)pid, SIGKILL);
	      }
	  }
	pclose(fp);
      }
  }

  return NO;
}
