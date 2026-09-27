/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
/*
 * Coverage for GWEnsureResponsivePasteboardServer: the gpbs-login fix.
 * Proves it against a real, registered Distributed Objects name server
 * (t_FakeGpbs, a separate process so its command name never collides
 * with this test's own) rather than a mirror of the logic under test.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../../GWPasteboardRecovery.h"
#import <Foundation/NSPortNameServer.h>
#include <errno.h>
#include <libgen.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static NSString * const kUnresponsiveName = @"t_GWPasteRecov_wedged_test";
static NSString * const kResponsiveName = @"t_GWPasteRecov_healthy_test";

/* t_FakeGpbs lives next to this test tool's own binary, wherever the
 * suite runner placed it - never assume the caller's working directory. */
static NSString *
helperPath(const char *argv0)
{
  char buf[4096];
  char *dir;

  strncpy(buf, argv0, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = '\0';
  dir = dirname(buf);
  return [NSString stringWithFormat: @"%s/t_FakeGpbs", dir];
}

static pid_t
spawnHelper(NSString *path, NSString *name, const char *mode)
{
  pid_t pid = fork();

  if (pid == 0)
    {
      execl([path fileSystemRepresentation], "t_FakeGpbs",
	[name UTF8String], mode, (char *)NULL);
      _exit(127); /* execl only returns on failure */
    }
  return pid;
}

static BOOL
waitForRegistration(NSString *name)
{
  int tries;

  for (tries = 0; tries < 100; tries++)
    {
      if ([[NSMessagePortNameServer sharedInstance] portForName: name] != nil)
	{
	  return YES;
	}
      usleep(20000); /* 20ms, up to 2s total */
    }
  return NO;
}

int main(int argc, char **argv)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *helper = helperPath(argv[0]);

  /* --- a wedged (registered but non-answering) server is detected and
   * killed, so a fresh one can take its place --- */
  {
    pid_t child = spawnHelper(helper, kUnresponsiveName, "wedge");
    BOOL registered = waitForRegistration(kUnresponsiveName);
    BOOL ok;

    PASS(registered, "the wedged helper registered its DO name");

    ok = GWEnsureResponsivePasteboardServer(kUnresponsiveName,
      "t_FakeGpbs", 1.0);
    PASS(ok == NO, "a registered but non-answering server is reported as"
      " needing recovery");

    /* Confirm the helper was really killed, not just that the function
     * claims so - reap it first (kill(pid, 0) alone would still say
     * "alive" for an unreaped zombie, which the SIGKILL alone leaves
     * behind) and check it died specifically by SIGKILL. */
    {
      int status = 0;
      pid_t reaped = 0;
      int tries;

      for (tries = 0; tries < 50 && reaped == 0; tries++)
	{
	  reaped = waitpid(child, &status, WNOHANG);
	  if (reaped == 0)
	    {
	      usleep(20000);
	    }
	}
      PASS(reaped == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
	"the wedged helper process was really killed");
    }
  }

  /* --- a genuinely responsive server is left running --- */
  {
    pid_t child = spawnHelper(helper, kResponsiveName, "run");
    BOOL registered = waitForRegistration(kResponsiveName);
    BOOL ok;

    PASS(registered, "the healthy helper registered its DO name");

    ok = GWEnsureResponsivePasteboardServer(kResponsiveName,
      "t_FakeGpbs_name_that_must_never_match", 1.0);
    PASS(ok == YES, "a server that answers in time is left alone");
    PASS(kill(child, 0) == 0,
      "the healthy helper process is still running afterwards");

    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
  }

  /* --- nothing registered at all is not treated as a problem --- */
  {
    BOOL ok = GWEnsureResponsivePasteboardServer(
      @"t_GWPasteRecov_nothing_here", "t_FakeGpbs", 1.0);
    PASS(ok == YES, "no registered server at all counts as already fine");
  }

  [arp release];
  return 0;
}
