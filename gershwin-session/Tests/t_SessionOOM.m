/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
/* t_SessionOOM.m - which supervised apps keep the session's OOM protection,
 * and the write into the kernel file.  Headless. */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "SessionOOM.h"

static int isText(const char *got, const char *want)
{
  return got != NULL && strcmp(got, want) == 0;
}

static int readInt(const char *path)
{
  char buf[32] = { 0 };
  FILE *fp = fopen(path, "r");

  if (fp == NULL)
    {
      return -9999;
    }
  if (fgets(buf, sizeof(buf), fp) == NULL)
    {
      buf[0] = '\0';
    }
  fclose(fp);
  return atoi(buf);
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("core apps keep the session's protection")
    PASS(GSSessionIsCoreApp("Menu"), "Menu is core");
    PASS(GSSessionIsCoreApp("Workspace"), "Workspace is core");
    PASS(GSSessionIsCoreApp("WindowManager"), "WindowManager is core");
    PASS(GSSessionIsCoreApp("/System/Library/CoreServices/Applications/Menu.app/Menu"),
      "a path to Menu is core");
    PASS(GSSessionOOMScoreAdjForApp("Menu") == NULL,
      "Menu inherits the supervisor's value");
    PASS(GSSessionOOMScoreAdjForApp("Workspace") == NULL,
      "Workspace inherits the supervisor's value");
    PASS(GSSessionOOMScoreAdjForApp("WindowManager") == NULL,
      "WindowManager inherits the supervisor's value");
  END_SET("core apps keep the session's protection")

  START_SET("every other app is killable as usual")
    PASS(!GSSessionIsCoreApp("gs-crashd"), "gs-crashd is not core");
    PASS(isText(GSSessionOOMScoreAdjForApp("gs-crashd"), "0"),
      "gs-crashd is started with 0");
    PASS(isText(GSSessionOOMScoreAdjForApp("networkmidid"), "0"),
      "networkmidid is started with 0");
    PASS(isText(GSSessionOOMScoreAdjForApp("Terminal"), "0"),
      "an app is started with 0");
    PASS(isText(GSSessionOOMScoreAdjForApp("MenuBar"), "0"),
      "a name that only starts like a core app is not core");
    PASS(isText(GSSessionOOMScoreAdjForApp("menu"), "0"),
      "core names are case sensitive like the binaries");
    PASS(isText(GSSessionOOMScoreAdjForApp("/opt/Menu/Terminal"), "0"),
      "a core name in a directory does not make the app core");
    PASS(isText(GSSessionOOMScoreAdjForApp(""), "0"),
      "an empty name is not core");
    PASS(isText(GSSessionOOMScoreAdjForApp(NULL), "0"), "NULL is not core");
  END_SET("every other app is killable as usual")

  START_SET("writing the kernel file")
    char path[64];
    int fd;

    snprintf(path, sizeof(path), "/tmp/t_SessionOOM.%d", (int)getpid());
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    close(fd);
    PASS(GSSessionWriteOOMScoreAdj(path, "0") == 0, "a writable file is written");
    PASS(readInt(path) == 0, "the value arrives");
    unlink(path);
    errno = 0;
    PASS(GSSessionWriteOOMScoreAdj("/nonexistent-dir/oom_score_adj", "0") == -1
      && errno == ENOENT, "a missing file fails with its errno");
  END_SET("writing the kernel file")

#if defined(__linux__)
  START_SET("a child raises itself back to 0 in the real kernel")
    /* A forked child first raises itself to 500 (allowed without
     * privilege), then does what the supervisor does for a non-core app;
     * it reports the value the kernel then holds as its exit status. */
    pid_t pid = fork();
    int status = 0;

    if (pid == 0)
      {
        int ok = GSSessionWriteOOMScoreAdj("/proc/self/oom_score_adj", "500");

        if (ok == 0 && readInt("/proc/self/oom_score_adj") == 500)
          {
            ok = GSSessionWriteOOMScoreAdj("/proc/self/oom_score_adj",
              GSSessionOOMScoreAdjForApp("Terminal"));
          }
        _exit(ok == 0 ? readInt("/proc/self/oom_score_adj") : 99);
      }
    waitpid(pid, &status, 0);
    PASS(WIFEXITED(status) && WEXITSTATUS(status) == 0,
      "the non-core child ends up at 0");
  END_SET("a child raises itself back to 0 in the real kernel")
#endif

  [arp release];
  return 0;
}
