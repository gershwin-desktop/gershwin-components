/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * sw_build_status_check <repo> <branch> <sha> - asks GitHub, through the
 * real SWGitHubBuildStatus, how the build of a commit went and prints the
 * status and every URL it had to fetch for it. A run that never touches
 * api.github.com is answered by the Actions page alone. Changes nothing.
 */

#import <Foundation/Foundation.h>
#import "SWGitHubBuildStatus.h"
#include <stdio.h>

int main(int argc, char **argv)
{
  @autoreleasepool {
    if (argc != 4) {
      fprintf(stderr, "usage: %s <repo> <branch> <sha>\n", argv[0]);
      return 2;
    }
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      printf("fetch %s\n", [[url absoluteString] UTF8String]);
      NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
      [request setValue:@"gershwin-desktop-software-update" forHTTPHeaderField:@"User-Agent"];
      [request setTimeoutInterval:30];
      NSURLResponse *response = nil;
      NSError *error = nil;
      NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
      printf("  -> %lu bytes%s\n", (unsigned long)[data length], error ? " (error)" : "");
      return data;
    }];
    SWBuildStatus s = [status statusForRepositoryNamed:[NSString stringWithUTF8String:argv[1]]
                                                branch:[NSString stringWithUTF8String:argv[2]]
                                                tipSha:[NSString stringWithUTF8String:argv[3]]];
    printf("status %ld (passed=%ld failed=%ld running=%ld unavailable=%ld)\n", (long)s,
           (long)SWBuildStatusPassed, (long)SWBuildStatusFailed, (long)SWBuildStatusRunning,
           (long)SWBuildStatusUnavailable);
  }
  return 0;
}
