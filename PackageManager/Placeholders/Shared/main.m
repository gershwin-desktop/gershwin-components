/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Placeholder app - main entry point.
 * Launches a window, reads install spec, installs packages if needed,
 * then runs the requested executable.
 */

#import <AppKit/NSApplication.h>
#import <Foundation/NSAutoreleasePool.h>
#import "OnDemandController.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      OnDemandController *controller = [[OnDemandController alloc] init];
      [[NSApplication sharedApplication] setDelegate:controller];

      if (![controller setupFromBundle])
        {
          NSLog(@"Placeholder [FAIL] main: failed to read install spec, exiting");
          return 1;
        }

      // If command is already available, launch silently and exit (no GUI)
      if ([controller commandIsAvailable])
        {
          NSLog(@"Placeholder -> main: command already installed, launching silently");
          [controller launchAndExit]; // never returns (calls exit() internally)
          return 1; // only reached if launchAndExit somehow returns
        }

      // Otherwise show progress window and install
      NSLog(@"Placeholder -> main: showing install window");
      [controller showWindow];

      dispatch_async(dispatch_get_main_queue(), ^{
        [controller performInstallAndLaunch];
      });
    }

  [[NSApplication sharedApplication] run];
  return 0;
}
