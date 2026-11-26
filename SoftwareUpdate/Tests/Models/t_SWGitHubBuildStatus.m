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

  /* --- the Actions page: the runs of pushes, read for one commit --- */
  {
    /* The real page of gershwin-workspace dev, 2026-10-14: this commit has a
     * passed and a still running run, that one a passed and a failed run. */
    NSString *fixture = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:@"actions_page_sample.html"];
    NSData *realPage = [NSData dataWithContentsOfFile:fixture];
    PASS([realPage length] > 1000, "the real page fixture is there");

    NSString *runningSha = @"33dfa5d345560e5c923a646be1dc76099e8019c2";
    NSString *passedSha = @"480c3289479b5a15eea3bfb3b9c2102f8acfe157";
    NSString *singleSha = @"01fa01b9cbc667a9d3f81a5d8d9c4d8924fd858b";
    NSString *failedSha = @"aa3dda997c82cab6d9eedfc8b23d2aec5ca4842f";
    NSString *unlistedSha = @"cccccccccccccccccccccccccccccccccccccccc";

    __block int apiCalls = 0, pageCalls = 0;
    __block NSData *page = nil;
    SWGitHubBuildStatus *status = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
      if ([[url host] isEqualToString:@"github.com"]) {
        pageCalls++;
        PASS([[url absoluteString] containsString:@"branch%3Adev"], "the page is asked for the branch");
        return page;
      }
      apiCalls++;
      return jsonData(@"{\"total_count\":1,\"check_runs\":[{\"status\":\"completed\",\"conclusion\":\"success\"}]}");
    }];

    /* answer is the status the page gave; the API in this fixture always says passed, so
     * a count of API calls tells where an answer came from */
    SWBuildStatus (^ask)(NSString *, NSString *) = ^SWBuildStatus(NSString *pageText, NSString *sha) {
      page = [pageText dataUsingEncoding:NSUTF8StringEncoding];
      [status clearCache];
      return [status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:sha];
    };
    NSString *(^wrap)(NSString *) = ^NSString *(NSString *json) {
      return [NSString stringWithFormat:@"<html><script type=\"application/json\" id=\"client-env\">{\"a\":1}</script>"
              @"<script type=\"application/json\" data-target=\"react-app.embeddedData\">%@</script></html>", json];
    };
    NSString *(^run)(NSString *, NSString *, NSString *) = ^NSString *(NSString *sha, NSString *st, NSString *concl) {
      return [NSString stringWithFormat:
        @"{\"workflowName\":\"w\",\"state\":{\"status\":\"%@\"%@},\"branch\":{\"name\":\"refs/heads/dev\"},"
        @"\"description\":{\"linkUrl\":\"/gershwin-desktop/r/commit/%@\"}}",
        st, concl ? [NSString stringWithFormat:@",\"conclusion\":\"%@\"", concl] : @"", sha];
    };

    page = realPage;
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:passedSha] == SWBuildStatusPassed
         && apiCalls == 0 && pageCalls == 1,
         "the real page: passed runs say passed, with no API request");
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:singleSha] == SWBuildStatusPassed, "the real page: one passed run");
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:runningSha] == SWBuildStatusRunning,
         "the real page: a run still going beats a passed run");
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:failedSha] == SWBuildStatusFailed,
         "the real page: a failed run beats a passed run");
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:[passedSha substringToIndex:10]] == SWBuildStatusPassed,
         "an abbreviated tip sha finds its runs");
    PASS(apiCalls == 0, "the real page needed no API request for any of them");
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:unlistedSha] == SWBuildStatusPassed && apiCalls == 1,
         "the real page has no run for the commit: the API is asked");

    /* constructed pages, same shape as the real one */
    NSString *tip = @"350f7ad7f66ec18a182d69cbda569c000529cc96";
    NSString *other = @"1562a98f7ad7f66ec18a182d69cbda569c000529";
    apiCalls = 0;
    NSString *list = [NSString stringWithFormat:@"{\"allWorkflowRunsRoute\":{\"workflowRuns\":[%@,%@,%@]}}",
      run(other, @"WORKFLOW_RUN_STATUS_COMPLETED", @"WORKFLOW_RUN_CONCLUSION_FAILURE"),
      run(tip, @"WORKFLOW_RUN_STATUS_COMPLETED", @"WORKFLOW_RUN_CONCLUSION_SUCCESS"),
      run(other, @"WORKFLOW_RUN_STATUS_IN_PROGRESS", nil)];
    PASS(ask(wrap(list), tip) == SWBuildStatusPassed && apiCalls == 0,
         "other commits' failed and running runs do not count for this one");

    list = [NSString stringWithFormat:@"{\"x\":[%@,%@]}",
      run(tip, @"WORKFLOW_RUN_STATUS_IN_PROGRESS", nil), run(tip, @"WORKFLOW_RUN_STATUS_COMPLETED", @"WORKFLOW_RUN_CONCLUSION_SUCCESS")];
    PASS(ask(wrap(list), tip) == SWBuildStatusRunning && apiCalls == 0, "a run still going on the tip is running");

    list = [NSString stringWithFormat:@"{\"x\":[%@,%@]}",
      run(tip, @"WORKFLOW_RUN_STATUS_COMPLETED", @"WORKFLOW_RUN_CONCLUSION_SUCCESS"),
      run(tip, @"WORKFLOW_RUN_STATUS_COMPLETED", @"WORKFLOW_RUN_CONCLUSION_TIMED_OUT")];
    PASS(ask(wrap(list), tip) == SWBuildStatusFailed && apiCalls == 0, "a failed run on the tip makes it failed");

    /* spellings of states: casing and prefixes do not matter, unknown ones are no pass */
    NSString *(^single)(NSString *, NSString *) = ^NSString *(NSString *st, NSString *concl) {
      return wrap([NSString stringWithFormat:@"[%@]", run(tip, st, concl)]);
    };
    PASS(ask(single(@"completed", @"success"), tip) == SWBuildStatusPassed, "lower case success passes");
    PASS(ask(single(@"Completed", @"Success"), tip) == SWBuildStatusPassed, "capitalised success passes");
    PASS(ask(single(@"WORKFLOW_RUN_STATUS_COMPLETED", @"CANCELLED"), tip) == SWBuildStatusFailed, "unprefixed cancelled fails");
    PASS(ask(single(@"completed", @"action_required"), tip) == SWBuildStatusFailed, "action required fails");
    PASS(ask(single(@"completed", @"failure"), tip) == SWBuildStatusFailed, "failure fails");
    PASS(ask(single(@"queued", nil), tip) == SWBuildStatusRunning, "queued is running");
    PASS(ask(single(@"WORKFLOW_RUN_STATUS_WAITING", nil), tip) == SWBuildStatusRunning, "waiting is running");
    PASS(ask(single(@"pending", nil), tip) == SWBuildStatusRunning, "pending is running");
    PASS(ask(single(@"requested", nil), tip) == SWBuildStatusRunning, "requested is running");
    PASS(ask(single(@"in_progress", nil), tip) == SWBuildStatusRunning, "in_progress is running");
    apiCalls = 0;
    PASS(ask(single(@"completed", nil), tip) == SWBuildStatusPassed && apiCalls == 1,
         "completed with no conclusion is no verdict: the API is asked");
    apiCalls = 0;
    PASS(ask(single(@"completed", @"WORKFLOW_RUN_CONCLUSION_FROBNICATED"), tip) == SWBuildStatusPassed && apiCalls == 1,
         "an unknown conclusion is not a pass: the API is asked");
    apiCalls = 0;
    PASS(ask(single(@"completed", @"skipped"), tip) == SWBuildStatusPassed && apiCalls == 1,
         "a skipped run is no pass: the API is asked");

    /* different nesting and key names: the run is whatever names a commit and says how it went */
    apiCalls = 0;
    NSString *moved = [NSString stringWithFormat:
      @"{\"payload\":{\"deep\":{\"items\":[{\"headSha\":\"%@\",\"run\":{\"result\":{\"conclusion\":\"FAILURE\"}}},"
      @"{\"headSha\":\"%@\",\"run\":{\"result\":{\"conclusion\":\"SUCCESS\"}}}]}}}", tip, other];
    PASS(ask(wrap(moved), tip) == SWBuildStatusFailed && apiCalls == 0,
         "a sha key and renamed, deeper nesting are still found");
    moved = [NSString stringWithFormat:@"[{\"checkSuite\":{\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\","
             @"\"link\":\"https://github.com/o/r/commit/%@\"}}]", tip];
    PASS(ask(wrap(moved), tip) == SWBuildStatusPassed && apiCalls == 0, "a full URL to the commit is found");
    NSString *split = [NSString stringWithFormat:@"{\"runs\":[{\"commit\":\"/o/r/commit/%@\"},"
                       @"{\"state\":{\"status\":\"COMPLETED\",\"conclusion\":\"FAILURE\"}}]}", tip];
    apiCalls = 0;
    PASS(ask(wrap(split), tip) == SWBuildStatusPassed && apiCalls == 1,
         "a verdict in one list entry is not lent to a commit in the next");

    /* a page that says nothing, or something broken: the API is asked */
    apiCalls = 0;
    PASS(ask(wrap(@"{\"allWorkflowRunsRoute\":{\"workflowRuns\":[]}}"), tip) == SWBuildStatusPassed && apiCalls == 1,
         "an empty run list: the API is asked");
    apiCalls = 0;
    PASS(ask(wrap(@"{\"workflowRuns\":[{\"state\":{\"status\":\"COMPL"), tip) == SWBuildStatusPassed && apiCalls == 1,
         "malformed JSON: the API is asked");
    apiCalls = 0;
    NSString *oldRows = [NSString stringWithFormat:
      @"<div class=\"Box-row\"><svg aria-label=\"failed: \"></svg><a href=\"/o/r/commit/%@\">x</a></div>", tip];
    PASS(ask(oldRows, tip) == SWBuildStatusPassed && apiCalls == 1,
         "a page without JSON, even the old rows: the API is asked, never a guess from the markup");
    apiCalls = 0;
    page = nil;
    [status clearCache];
    PASS([status statusForRepositoryNamed:@"r" branch:@"dev" tipSha:tip] == SWBuildStatusPassed && apiCalls == 1,
         "no page at all: the API is asked");
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
