/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@protocol BacklightBackend <NSObject>
- (int)current;
- (int)maximum;
- (void)set:(int)value;
@end

/* Every operating system exposes the display backlight differently; this
 * returns a retained backend for the running one, or nil if there is no
 * backlight this user may control.  Retained because the menu extras that
 * call it are built without ARC. */
id<BacklightBackend> BacklightBackendCreateDefault(void) NS_RETURNS_RETAINED;
