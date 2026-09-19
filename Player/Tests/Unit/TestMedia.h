/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Writes a silent 8 kHz mono WAV of the given length to a unique temporary
 * path and returns that path.  The caller removes it. */
NSString *TestMediaWriteSilentWAV(NSString *tag, NSTimeInterval seconds);
