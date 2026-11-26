/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "AGAppDelegate.h"

/* The delegate is created here rather than named in the Info plist: this
 * AppKit reads no delegate class from the plist, so a nib-less app has to
 * set it before the run loop starts. Kept in a static so ARC does not
 * release it when main's scope would otherwise end for it. */
static AGAppDelegate *gDelegate = nil;

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      gDelegate = [[AGAppDelegate alloc] init];
      [[NSApplication sharedApplication] setDelegate:gDelegate];
    }
  return NSApplicationMain(argc, argv);
}
