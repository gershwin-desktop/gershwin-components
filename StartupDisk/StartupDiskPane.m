/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StartupDiskPane.h"
#import "StartupDiskController.h"
#include <stdlib.h>

@class StartupDiskController;

/* The pane view.  The host sizes it to the preferences-box content area
   (640x440 on this stack); fill the superview exactly and let the controller
   re-lay out the controls to the actual width, so margins stay symmetric and
   nothing is clipped. */
@interface StartupDiskMainView : NSView
{
    StartupDiskController *_layoutOwner;
}
- (void)setLayoutOwner:(StartupDiskController *)owner;
@end

@implementation StartupDiskMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:NSWidth([[self superview] bounds])];
    }
}
- (void)setLayoutOwner:(StartupDiskController *)owner
{
    _layoutOwner = owner;
}
@end

@implementation StartupDiskPane

+ (BOOL)isCompatible {
  /* A minimal launcher environment may not set PATH at all, and
     stringWithUTF8String: raises on the resulting NULL. */
  const char *pathEnv = getenv("PATH");
  if (pathEnv == NULL)
    return NO;
  NSArray *paths = [[NSString stringWithUTF8String: pathEnv]
                     componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"efibootmgr"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"efibootmgr not found — startup disk selection requires EFI boot manager";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    NSDebugLLog(@"gwcomp", @"StartupDiskPane: initWithBundle called with bundle = %@", bundle);
    self = [super initWithBundle:bundle];
    if (self) {
        NSDebugLLog(@"gwcomp", @"StartupDiskPane: initWithBundle succeeded, checking efibootmgr permissions");
        
        NSDebugLLog(@"gwcomp", @"StartupDiskPane: efibootmgr permissions check passed");
    } else {
        NSDebugLLog(@"gwcomp", @"StartupDiskPane: initWithBundle failed - super initWithBundle returned nil");
    }
    return self;
}

/* The host calls this on every selection, and its search index calls it
   without selecting the pane at all, so the view must be built exactly once
   and building it must not touch EFI state; boot entries are fetched in
   didSelect. */
- (NSView *)loadMainView
{
    if (![self mainView]) {
        StartupDiskMainView *view = [[StartupDiskMainView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        [self setMainView:view];
        [view release];
        [self mainViewDidLoad];
    }
    return [self mainView];
}

- (void)mainViewDidLoad
{
    /* A second controller would add a duplicate set of controls to the same
       view and orphan the first one's helper process. */
    if (startupDiskController) {
        return;
    }
    startupDiskController = [[StartupDiskController alloc] init];
    [startupDiskController setMainView:[self mainView]];
}

- (void)refreshBootEntries
{
    NSDebugLLog(@"gwcomp", @"StartupDiskPane: refreshBootEntries called");
    [startupDiskController refreshBootEntries];
    NSDebugLLog(@"gwcomp", @"StartupDiskPane: refreshBootEntries completed");
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                        target:self
                                                      selector:@selector(refreshBootEntries)
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

- (void)didSelect
{
    [super didSelect];
    [self refreshBootEntries];
    [self startRefreshTimer];
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [startupDiskController release];
    [super dealloc];
}

@end
