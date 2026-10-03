/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSCrashReporter.h"
#import <sys/resource.h>

int main(int argc, char **argv)
{
  @autoreleasepool
    {
      /* Allow an unlimited core file size so the kernel writes "core". */
      struct rlimit rl;
      rl.rlim_cur = RLIM_INFINITY;
      rl.rlim_max = RLIM_INFINITY;
      setrlimit(RLIMIT_CORE, &rl);

      /* Install the lightweight crash integration. This clearly marks the
       * crash as a TEST crash so it is never confused with a real one. */
      [GSCrashReporter setApplicationName:@"gs-crash-test"];
      [GSCrashReporter setApplicationVersion:@"1.0"];
      [GSCrashReporter install];

      /* Intentional crash: dereference a NULL pointer -> SIGSEGV. */
      int *p = 0;
      *p = 42;
    }
  return 0;
}
