/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

/* Does nothing but run; the CrashHandler bundle crashes it when GSCrashHandlerTest is set. */
int main(int argc, const char *argv[])
{
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 120)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Crash Test"];
    [window makeKeyAndOrderFront:nil];
    [app run];
  }
  return 0;
}
