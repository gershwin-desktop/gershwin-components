/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "BacklightBackend.h"

/* The wscons display brightness parameter, as set by
 * "wsconsctl display.brightness" on OpenBSD and NetBSD. */
@interface WsconsBacklightBackend : NSObject <BacklightBackend>
@end
