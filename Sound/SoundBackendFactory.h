/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundBackend.h"

/* The Sound pane, the Sound menu extra and Menu's volume keys must all talk
 * to the same mixer, so the choice of backend for the running system is made
 * in one place.  Returns a retained backend, or nil if the system has none.
 * Blocking: a backend enumerates its devices while initializing. */
id<SoundBackend> SoundBackendCreateDefault(void) NS_RETURNS_RETAINED;
