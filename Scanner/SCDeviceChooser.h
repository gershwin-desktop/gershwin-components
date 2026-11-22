/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCDeviceChooser, SCDeviceInfo;

@protocol SCDeviceChooserDelegate <NSObject>
- (void) deviceChooser: (SCDeviceChooser *)chooser didChooseDevice: (SCDeviceInfo *)device;
/* NO keeps the chooser from searching, e.g. while SANE is not installed */
- (BOOL) deviceChooserShouldSearch: (SCDeviceChooser *)chooser;
/* Called after each search, before the automatic open */
- (void) deviceChooser: (SCDeviceChooser *)chooser didFindDevices: (NSArray *)devices;
/* Called after each search; return YES to open `device` without asking */
- (SCDeviceInfo *) deviceChooser: (SCDeviceChooser *)chooser
       deviceToOpenAutomaticallyFrom: (NSArray *)devices;
@end

/* Window that searches for scanners in the background and lets the user pick one */
@interface SCDeviceChooser : NSWindowController

@property (nonatomic, weak) id<SCDeviceChooserDelegate> delegate;

- (void) showAndSearch;
- (void) setBusy: (BOOL)busy message: (NSString *)message;

@end
