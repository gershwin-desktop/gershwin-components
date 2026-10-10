/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "KCAppDelegate.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      NSApplication *app = [NSApplication sharedApplication];
      KCAppDelegate *delegate = [KCAppDelegate new];

      [app setDelegate: delegate];
      [app run];
    }
  return 0;
}
