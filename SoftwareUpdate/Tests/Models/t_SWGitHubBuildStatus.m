/* t_SWGitHubBuildStatus.m - ObjectTesting coverage for SWGitHubBuildStatus.
 * Headless: the HTTP fetcher is injected, so no real network is used.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWGitHubBuildStatus.h"

static NSData *jsonData(NSString *json)
{
  return [json dataUsingEncoding:NSUTF8StringEncoding];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- all check runs completed successfully --- */
  {
    __block NSUInteger callCount = 0;
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      callCount++;
      return jsonData(@"{\"total_count\":1,\"check_runs\":["
                        "{\"status\":\"completed\",\"conclusion\":\"success\"}]}");
    }];

    PASS([status statusForRepositoryNamed:@"gershwin-workspace" sha:@"abc123"] == SWBuildStatusPassed,
         "a single successful completed check run reports passed");
    PASS(callCount == 1, "the fetcher is called exactly once for a new sha");
  }

  /* --- one run still running blocks the whole result --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":2,\"check_runs\":["
                        "{\"status\":\"completed\",\"conclusion\":\"success\"},"
                        "{\"status\":\"in_progress\",\"conclusion\":null}]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-workspace" sha:@"def456"] == SWBuildStatusRunning,
         "any non-completed run reports running, even if others passed");
  }

  /* --- one failed completed run marks the whole result failed --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":2,\"check_runs\":["
                        "{\"status\":\"completed\",\"conclusion\":\"success\"},"
                        "{\"status\":\"completed\",\"conclusion\":\"failure\"}]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-terminal" sha:@"111111"] == SWBuildStatusFailed,
         "a failed completed run reports failed even alongside a passing one");
  }

  /* --- no check runs at all reports unknown, not failed --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":0,\"check_runs\":[]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-textedit" sha:@"222222"] == SWBuildStatusUnknown,
         "no check runs at all reports unknown");
  }

  /* --- unreachable / unparsable response reports unknown, never a guess --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return nil; // simulates a network failure or rate limit
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-eau-theme" sha:@"333333"] == SWBuildStatusUnknown,
         "a failed fetch reports unknown rather than a false pass or fail");
  }

  /* --- caching: the same sha is never fetched twice --- */
  {
    __block NSUInteger callCount = 0;
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      callCount++;
      return jsonData(@"{\"total_count\":1,\"check_runs\":["
                        "{\"status\":\"completed\",\"conclusion\":\"success\"}]}");
    }];
    [status statusForRepositoryNamed:@"gershwin-workspace" sha:@"cached-sha"];
    [status statusForRepositoryNamed:@"gershwin-workspace" sha:@"cached-sha"];
    [status statusForRepositoryNamed:@"gershwin-workspace" sha:@"cached-sha"];
    PASS(callCount == 1, "repeated queries for the same sha only fetch once");

    [status clearCache];
    [status statusForRepositoryNamed:@"gershwin-workspace" sha:@"cached-sha"];
    PASS(callCount == 2, "clearing the cache allows a fresh fetch");
  }

  [arp release];
  return 0;
}
