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

  /* --- the same check run twice: one passing run is enough --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":2,\"check_runs\":["
                        "{\"name\":\"FreeBSD\",\"status\":\"completed\",\"conclusion\":\"failure\"},"
                        "{\"name\":\"FreeBSD\",\"status\":\"completed\",\"conclusion\":\"success\"}]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-developer" sha:@"rerun1"] == SWBuildStatusPassed,
         "a check that failed in one run and passed in another reports passed");
  }
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":2,\"check_runs\":["
                        "{\"name\":\"Arch\",\"status\":\"completed\",\"conclusion\":\"success\"},"
                        "{\"name\":\"FreeBSD\",\"status\":\"completed\",\"conclusion\":\"failure\"}]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-developer" sha:@"distinct1"] == SWBuildStatusFailed,
         "a different check that failed still reports failed");
  }
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":2,\"check_runs\":["
                        "{\"name\":\"Debian\",\"status\":\"in_progress\",\"conclusion\":null},"
                        "{\"name\":\"Debian\",\"status\":\"completed\",\"conclusion\":\"success\"}]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-developer" sha:@"dup-running"] == SWBuildStatusPassed,
         "a check still running in one run but passed in another reports passed");
  }

  /* --- no check runs at all reports unknown, not failed --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return jsonData(@"{\"total_count\":0,\"check_runs\":[]}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-textedit" sha:@"222222"] == SWBuildStatusUnknown,
         "no check runs at all reports unknown");
  }

  /* --- the rate limit message is an answer that is no answer, and is asked again --- */
  {
    __block int asked = 0;
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      asked++;
      return jsonData(@"{\"message\":\"API rate limit exceeded\"}");
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-developer" sha:@"dev"] == SWBuildStatusUnavailable,
         "a rate limit response is unavailable, not a pass");
    [status statusForRepositoryNamed:@"gershwin-developer" sha:@"dev"];
    PASS(asked == 2, "an answer that is no answer is not kept: the next ask asks again");
  }

  /* --- unreachable / unparsable response is unavailable: never a guess, and never a pass --- */
  {
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      return nil; // simulates a network failure or rate limit
    }];
    PASS([status statusForRepositoryNamed:@"gershwin-eau-theme" sha:@"333333"] == SWBuildStatusUnavailable,
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
