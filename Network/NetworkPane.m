/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Preference Pane Implementation
 */

#import "NetworkPane.h"
#import "NetworkController.h"
#include <stdlib.h>

@implementation NetworkPane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"nmcli"]])
      return YES;
  }
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"ifconfig"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"Neither nmcli nor ifconfig found on PATH — Network configuration requires one of these";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[NetworkController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [controller stopRefreshing];
    [controller release];
    [super dealloc];
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
    return nil; // We create the view programmatically
}

/* The host also loads the main view without selecting the pane (to index
   its widgets for search), so all data loading waits for selection. */
- (void)didSelect
{
    [super didSelect];
    [controller startRefreshing];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    NSDebugLLog(@"gwcomp", @"NetworkPane: willUnselect called");
    [controller stopRefreshing];
}

- (void)didUnselect
{
    [super didUnselect];
    NSDebugLLog(@"gwcomp", @"NetworkPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    NSDebugLLog(@"gwcomp", @"NetworkPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

@end
