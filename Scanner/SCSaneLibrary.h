/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sane/sane.h>

/*
 * libsane, loaded when scanning is first needed rather than linked: SANE
 * is not part of a default Gershwin system, and Scanner has to start
 * without it so it can offer to install it.
 */
typedef struct
{
  SANE_Status (*init)(SANE_Int *version, SANE_Auth_Callback authorize);
  void (*exit)(void);
  SANE_Status (*get_devices)(const SANE_Device ***list, SANE_Bool localOnly);
  SANE_Status (*open)(SANE_String_Const name, SANE_Handle *handle);
  void (*close)(SANE_Handle handle);
  const SANE_Option_Descriptor *(*get_option_descriptor)(SANE_Handle handle,
                                                          SANE_Int option);
  SANE_Status (*control_option)(SANE_Handle handle, SANE_Int option,
                                SANE_Action action, void *value, SANE_Int *info);
  SANE_Status (*get_parameters)(SANE_Handle handle, SANE_Parameters *params);
  SANE_Status (*start)(SANE_Handle handle);
  SANE_Status (*read)(SANE_Handle handle, SANE_Byte *data, SANE_Int maxLength,
                      SANE_Int *length);
  void (*cancel)(SANE_Handle handle);
  SANE_String_Const (*strstatus)(SANE_Status status);
} SCSaneFunctions;

/* The functions, or NULL with *error set when libsane is not installed */
const SCSaneFunctions *SCSaneLoad(NSError **error);

/* Error code of SCSaneLoad when the library is missing */
enum { SCSaneNotInstalledError = 100 };
