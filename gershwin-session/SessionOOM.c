/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "SessionOOM.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

/* The processes without which the desktop is gone: the menu bar, the
 * desktop and file manager that launches applications, and the window
 * manager.  Everything else can be restarted or reopened by the user. */
static const char *const coreApps[] = { "Menu", "Workspace", "WindowManager" };

int GSSessionIsCoreApp(const char *name)
{
  const char *base;
  size_t i;

  if (name == NULL)
    {
      return 0;
    }
  /* Gershwin.sh passes bare names, but a flavor may pass a path. */
  base = strrchr(name, '/');
  base = (base != NULL) ? base + 1 : name;
  for (i = 0; i < sizeof(coreApps) / sizeof(coreApps[0]); i++)
    {
      if (strcmp(base, coreApps[i]) == 0)
        {
          return 1;
        }
    }
  return 0;
}

const char *GSSessionOOMScoreAdjForApp(const char *name)
{
  /* 0 is the kernel's default: the app is judged by its size alone. */
  return GSSessionIsCoreApp(name) ? NULL : "0";
}

int GSSessionWriteOOMScoreAdj(const char *path, const char *value)
{
  size_t len = strlen(value);
  int fd = open(path, O_WRONLY);
  int saved;

  if (fd < 0)
    {
      return -1;
    }
  if (write(fd, value, len) != (ssize_t)len)
    {
      saved = errno;
      close(fd);
      errno = saved;
      return -1;
    }
  if (close(fd) != 0)
    {
      return -1;
    }
  return 0;
}
