/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * sw_pkg_check - runs Software Update's NextBSD package check end to end
 * against the real pkg configuration and the real repository, as the user,
 * and prints what the list item would show. Changes nothing.
 *
 * SW_PKG_CHECK_FAKE_INSTALLED=<name>=<version> makes pkg query report that
 * version for that package, so a pending upgrade can be seen on a system
 * that is current. Only this tool reads it; the app never does.
 */

#import <Foundation/Foundation.h>
#import "SWSystemPackages.h"
#include <stdio.h>
#include <stdlib.h>

static SWCommandOutputRunner fakingRunner(NSString *fakeName, NSString *fakeVersion)
{
  SWCommandOutputRunner real = SWDefaultCommandOutputRunner();
  return ^NSString *(NSString *path, NSArray<NSString *> *args, int *status) {
    NSString *output = real(path, args, status);
    if (!fakeName || ![[args firstObject] isEqualToString:@"query"]) return output;
    NSMutableArray *lines = [NSMutableArray array];
    for (__strong NSString *line in [output componentsSeparatedByString:@"\n"]) {
      NSArray *fields = [line componentsSeparatedByString:@" "];
      if ([fields count] == 3 && [fields[1] isEqualToString:fakeName]) {
        line = [NSString stringWithFormat:@"%@ %@ %@", fields[0], fields[1], fakeVersion];
      }
      [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
  };
}

int main(void)
{
  @autoreleasepool {
    NSString *fakeName = nil, *fakeVersion = nil;
    const char *fake = getenv("SW_PKG_CHECK_FAKE_INSTALLED");
    if (fake) {
      NSArray *parts = [[NSString stringWithUTF8String:fake] componentsSeparatedByString:@"="];
      if ([parts count] != 2) {
        fprintf(stderr, "SW_PKG_CHECK_FAKE_INSTALLED must be <name>=<version>\n");
        return 2;
      }
      fakeName = parts[0];
      fakeVersion = parts[1];
      printf("faking installed %s %s\n", [fakeName UTF8String], [fakeVersion UTF8String]);
    }

    SWSystemPackageChecker *checker =
      [[SWSystemPackageChecker alloc] initWithRepositoryName:SWNextBSDRepositoryName
                                               commandRunner:fakingRunner(fakeName, fakeVersion)
                                                  logHandler:^(NSString *line) {
        printf("log: %s\n", [line UTF8String]);
      }];
    NSArray<SWSystemPackageUpgrade *> *pending = [checker pendingUpgrades];
    if (!pending) {
      printf("check failed: the NextBSD item would not appear\n");
      return 1;
    }
    SWRepository *item = [SWRepository systemPackagesItemNamed:SWNextBSDRepositoryName upgrades:pending];
    printf("pending: %lu, item shown: %s, restart required: %s\n", (unsigned long)[pending count],
           [item hasUpdate] ? "yes" : "no", [item restartRequired] ? "yes" : "no");
    for (SWSystemPackageUpgrade *upgrade in pending) {
      printf("  %s\n", [[upgrade displayLine] UTF8String]);
    }
  }
  return 0;
}
