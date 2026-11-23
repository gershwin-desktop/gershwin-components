/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PrintersPane.h"
#import "PrintersController.h"
#include <cups/cups.h>

@implementation PrintersPane

/* The pane stays visible without cupsd: OnDemand offers to install CUPS, from
   the Dependencies.plist in this bundle, when the pane is selected. */
+ (BOOL)isCompatible {
    return YES;
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[PrintersController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [controller release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                        target:controller
                                                      selector:@selector(refreshPrinters:)
                                                      userInfo:nil
                                                       repeats:YES];
        [refreshTimer retain];
    }
}

- (void)stopRefreshTimer
{
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
        refreshTimer = nil;
    }
}

- (NSView *)loadMainView
{
    if (_mainView == nil) {
        _mainView = [[controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil;
}

- (void)willSelect
{
    [super willSelect];
    /* Re-checked on every selection because cupsd may have been started or
       stopped since the pane was last shown. */
    [controller checkCupsAndPrivileges];
}

- (void)didSelect
{
    [super didSelect];
    [controller refreshPrinters:nil];
    [self startRefreshTimer];
    [self setInitialKeyView:nil];
    [controller showPrivilegeWarningIfNeeded];
}

- (void)willUnselect
{
    NSDebugLLog(@"gwcomp", @"PrintersPane: willUnselect called");
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
    NSDebugLLog(@"gwcomp", @"PrintersPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    NSDebugLLog(@"gwcomp", @"PrintersPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

@end
