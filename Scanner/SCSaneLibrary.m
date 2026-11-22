/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCSaneLibrary.h"
#import "SCImageBuilder.h"
#include <dlfcn.h>

static SCSaneFunctions functions;
static BOOL loaded;

const SCSaneFunctions *
SCSaneLoad(NSError **error)
{
  /*
   * The ABI version 1 name everywhere but OpenBSD, whose versioned names
   * (libsane.so.X.Y) ld.so finds from the plain name
   */
  static const char *names[] = { "libsane.so.1", "libsane.so", NULL };
  void *lib = NULL;
  const char **n;

  if (loaded)
    {
      return &functions;
    }
  for (n = names; *n != NULL && lib == NULL; n++)
    {
      lib = dlopen(*n, RTLD_NOW | RTLD_GLOBAL);
    }
  if (lib == NULL)
    {
      if (error)
        {
          *error = [NSError errorWithDomain: SCScannerErrorDomain
                                       code: SCSaneNotInstalledError
                                   userInfo: @{NSLocalizedDescriptionKey:
                                     @"Scanner support (SANE) is not installed."}];
        }
      return NULL;
    }

#define SC_BIND(field, symbol) \
  *(void **)(&functions.field) = dlsym(lib, symbol); \
  if (functions.field == NULL) \
    { \
      if (error) \
        { \
          *error = [NSError errorWithDomain: SCScannerErrorDomain code: 101 \
                                   userInfo: @{NSLocalizedDescriptionKey: \
            [NSString stringWithFormat: @"The installed SANE library lacks %s.", \
                      symbol]}]; \
        } \
      dlclose(lib); \
      return NULL; \
    }

  SC_BIND(init, "sane_init");
  SC_BIND(exit, "sane_exit");
  SC_BIND(get_devices, "sane_get_devices");
  SC_BIND(open, "sane_open");
  SC_BIND(close, "sane_close");
  SC_BIND(get_option_descriptor, "sane_get_option_descriptor");
  SC_BIND(control_option, "sane_control_option");
  SC_BIND(get_parameters, "sane_get_parameters");
  SC_BIND(start, "sane_start");
  SC_BIND(read, "sane_read");
  SC_BIND(cancel, "sane_cancel");
  SC_BIND(strstatus, "sane_strstatus");
#undef SC_BIND

  loaded = YES;
  return &functions;
}
