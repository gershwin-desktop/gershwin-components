/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "BacklightBackend.h"

/* backlight(9) devices, available since FreeBSD 13.  Brightness is a
 * percentage. */
@interface FreeBSDBacklightBackend : NSObject <BacklightBackend>
@end
