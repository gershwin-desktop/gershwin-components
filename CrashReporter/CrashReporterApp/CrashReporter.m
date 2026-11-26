/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CrashReporterController.h"
#import <GSCrashReport.h>
#import <GSCrashConstants.h>
#import <GSCrashPlatform.h>

int
main (int argc, const char *argv[])
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      CrashReporterController *controller =
        [[CrashReporterController alloc] init];
      [NSApp setDelegate:controller];
      [NSApp run];
    }
  return 0;
}
