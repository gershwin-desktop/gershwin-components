/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* The slim strip under the top bar that tells the user the catalog on screen
   is stale or could not be fetched, with one Retry button. The window
   controller decides when it is shown; this only draws it and reports the
   click. */
@interface AGStatusBannerController : NSObject

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;

+ (CGFloat)height;

@end
