/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include "qt-metadata.h"

void gad_qt_start(void);

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
  gad_qt_start();
  return NULL;
}
