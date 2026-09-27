/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */
/*
 * t_FakeGpbs: a tiny helper process for t_GWPasteRecov, not a test itself.
 *
 * Registers a Distributed Objects name and then either runs its run loop
 * (a healthy server) or calls pause() without ever running one (the real
 * gpbs bug: registered, its socket alive and connectable, but nothing
 * ever answers a round trip because the process never turns a run loop).
 *
 * Usage: t_FakeGpbs <name> <run|wedge>
 */
#import <Foundation/Foundation.h>
#import <Foundation/NSConnection.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
  @autoreleasepool
    {
      NSConnection *conn;
      NSString *name;

      if (argc < 3)
        {
          /* Not a test on its own - the suite runner still executes every
           * TEST_TOOL_NAME once with no arguments, so exit cleanly rather
           * than reporting a "failed" build for a helper that has nothing
           * to check. t_GWPasteRecov is what actually exercises this. */
          fprintf(stderr,
            "%s: helper for t_GWPasteRecov, not a standalone test\n",
            argv[0]);
          return 0;
        }

      name = [NSString stringWithUTF8String: argv[1]];
      conn = [NSConnection new];
      [conn setRootObject: [NSObject new]];
      if ([conn registerName: name] == NO)
        {
          fprintf(stderr, "%s: registerName: failed\n", argv[0]);
          return 2;
        }

      if (strcmp(argv[2], "run") == 0)
        {
          [[NSRunLoop currentRunLoop] run];
        }
      else
        {
          pause();
        }
    }
  return 0;
}
