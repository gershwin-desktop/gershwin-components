/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* What the top bar shows for a page on the navigation stack. This AppKit's
   NSViewController copies its own title onto the window, so pages carry
   their title under a separate name. */
@protocol AGPage <NSObject>
@property (nonatomic, copy) NSString *pageTitle;
@end
