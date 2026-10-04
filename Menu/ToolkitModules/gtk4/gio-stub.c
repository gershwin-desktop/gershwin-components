/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The GIO module GLib loads from $GIO_EXTRA_MODULES.  Every GLib program loads
 * it, GTK 4 or not, so it is kept tiny and depends on nothing: only a program
 * that runs GTK 4 gets the real code (libgad-gtk4-core.so), which brings the
 * Objective-C runtime and Foundation with it. */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

void g_io_module_load(void *module)
{
  unsigned (*major)(void);
  Dl_info where;
  char path[1024];
  char *slash;
  void *core;
  void (*start)(void);
  (void)module;

  *(void **)&major = dlsym(RTLD_DEFAULT, "gtk_get_major_version");
  if (major == NULL || major() != 4)
    return;
  if (!dladdr((void *)g_io_module_load, &where) || strlen(where.dli_fname) >= sizeof path - 40)
    return;
  strcpy(path, where.dli_fname);
  /* .../gio/modules/libgad-gio.so -> .../lib/libgad-gtk4-core.so */
  for (int up = 0; up < 3; up++)
    {
      slash = strrchr(path, '/');
      if (slash == NULL)
        return;
      *slash = '\0';
    }
  strcat(path, "/lib/libgad-gtk4-core.so");
  /* The handle is never closed: GIO unloads this module as soon as it returns,
     the core and its threads have to stay. */
  core = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (core == NULL)
    {
      fprintf(stderr, "gtk4-appmenu-do: %s\n", dlerror());
      return;
    }
  *(void **)&start = dlsym(core, "gad_gtk4_start");
  if (start)
    start();
}

void g_io_module_unload(void *module)
{
  (void)module;
}

char **g_io_module_query(void)
{
  return NULL;
}
