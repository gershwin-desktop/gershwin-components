/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The part of the Qt plugin that Qt looks at.  Qt 6 only accepts a platform
 * plugin that was built for the minor version it runs, so there is one of these
 * tiny files per minor version (libgad-qt6-N.so, from the same source with
 * GAD_QT6_MINOR set) and a single copy of the real code, libgad-qt-core.so,
 * which the one that matches loads. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "qt-metadata.h"

const void *qt_plugin_query_metadata(void) { return gad_qt5_metadata; }

struct gad_plugin_meta { const void *data; unsigned long size; };
struct gad_plugin_meta qt_plugin_query_metadata_v2(void)
{
  struct gad_plugin_meta r = { gad_qt6_desc, sizeof gad_qt6_desc };
  return r;
}

void *qt_plugin_instance(void)
{
  /* Qt asks for the plugin when it creates the platform theme, on the main
     thread of the program.  Returning no object makes it use its own theme. */
  Dl_info where;
  char path[1024];
  void *core;
  void (*start)(void);
  char *slash;

  if (!dladdr((void *)qt_plugin_instance, &where) || strlen(where.dli_fname) >= sizeof path - 32)
    return NULL;
  strcpy(path, where.dli_fname);
  slash = strrchr(path, '/');
  if (slash == NULL)
    return NULL;
  /* .../platformthemes/libgad-qt6-N.so -> .../lib/libgad-qt-core.so */
  *slash = '\0';
  slash = strrchr(path, '/');
  if (slash == NULL)
    return NULL;
  strcpy(slash, "/lib/libgad-qt-core.so");
  core = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (core == NULL)
    {
      fprintf(stderr, "qt-appmenu-do: %s\n", dlerror());
      return NULL;
    }
  *(void **)&start = dlsym(core, "gad_qt_start");
  if (start)
    start();
  return NULL;
}
