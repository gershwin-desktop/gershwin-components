/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "TDAppDelegate.h"

int
main(int argc, const char *argv[])
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  TDAppDelegate *delegate = [[TDAppDelegate alloc] init];

  [NSApplication sharedApplication];
  [NSApp setDelegate: delegate];
  [pool release];
  return NSApplicationMain(argc, argv);
}
