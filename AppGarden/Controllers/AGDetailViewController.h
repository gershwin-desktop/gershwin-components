/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "AGPage.h"

@class AGApp, AGImageCache, AGInstaller;

/* The page for one application: header with icon, links and the install
   button, the screenshot, the description and the information table. All
   widths follow the page width, so the page relayouts itself on resize. */
@interface AGDetailViewController : NSViewController <AGPage>

- (instancetype)initWithApp:(AGApp *)app
                 imageCache:(AGImageCache *)imageCache
                  installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly, strong) AGApp *app;

@end
