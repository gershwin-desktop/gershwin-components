/* t_SWUpdateChecker.m - ObjectTesting coverage for SWUpdateChecker, against
 * real scratch git repositories (branched + pinned) with an injected
 * (non-networked) GitHub build-status client.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWRepository.h"
#import "SWRepositoryList.h"
#import "SWUpdateChecker.h"
#include <stdlib.h>
#include <unistd.h>

static void runShell(NSString *cmd)
{
  system([cmd UTF8String]);
}

static NSString *shellOutput(NSString *cmd)
{
  FILE *f = popen([cmd UTF8String], "r");
  if (!f) return @"";
  char buf[256] = {0};
  fgets(buf, sizeof(buf), f);
  pclose(f);
  NSString *s = [NSString stringWithUTF8String:buf];
  return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *base = [NSString stringWithFormat:@"/tmp/sw-checker-test-%d", getpid()];
  NSString *originDir = [base stringByAppendingPathComponent:@"origin"];
  NSString *sourcesDir = [base stringByAppendingPathComponent:@"Sources"];
  runShell([NSString stringWithFormat:@"rm -rf %@ && mkdir -p %@ %@", base, originDir, sourcesDir]);

  /* --- libobjc2: an upstream library whose pin is about to advance --- */
  NSString *originLibobjc2 = [originDir stringByAppendingPathComponent:@"libobjc2"];
  NSString *workLibobjc2 = [sourcesDir stringByAppendingPathComponent:@"libobjc2"];
  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
     "git config user.name T && echo a > f.txt && git add f.txt && git commit -q -m A",
    originLibobjc2, originLibobjc2]);
  runShell([NSString stringWithFormat:@"git clone -q %@ %@", originLibobjc2, workLibobjc2]);
  runShell([NSString stringWithFormat:
    @"cd %@ && echo b >> f.txt && git commit -q -am B", originLibobjc2]);
  NSString *newPinSha = shellOutput([NSString stringWithFormat:@"cd %@ && git rev-parse HEAD", originLibobjc2]);

  /* --- gershwin-workspace: an ordinary Gershwin repo, two commits behind --- */
  NSString *originWorkspace = [originDir stringByAppendingPathComponent:@"gershwin-workspace"];
  NSString *workWorkspace = [sourcesDir stringByAppendingPathComponent:@"gershwin-workspace"];
  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
     "git config user.name T && echo a > f.txt && git add f.txt && git commit -q -m first",
    originWorkspace, originWorkspace]);
  runShell([NSString stringWithFormat:@"git clone -q %@ %@", originWorkspace, workWorkspace]);
  runShell([NSString stringWithFormat:
    @"cd %@ && echo b >> f.txt && git commit -q -am second && "
     "echo c >> f.txt && git commit -q -am third", originWorkspace]);

  /* --- gershwin-developer: declares libobjc2's incoming pin --- */
  NSString *originDeveloper = [originDir stringByAppendingPathComponent:@"gershwin-developer"];
  NSString *workDeveloper = [sourcesDir stringByAppendingPathComponent:@"gershwin-developer"];
  NSString *csv = [NSString stringWithFormat:
    @"Name,URL,Pin,RestartRequired\n"
     "gershwin-workspace,u,,\n"
     "libobjc2,u,%@,\n", newPinSha];
  runShell([NSString stringWithFormat:
    @"git init -q -b main %@ && cd %@ && git config user.email t@x.invalid && "
     "git config user.name T && mkdir -p Library && printf '%@' > Library/Repositories.csv && "
     "git add Library/Repositories.csv && git commit -q -m csv",
    originDeveloper, originDeveloper, csv]);
  runShell([NSString stringWithFormat:@"git clone -q %@ %@", originDeveloper, workDeveloper]);

  /* --- build the repository list and run the checker --- */
  NSArray *entries = @[
    [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"gershwin-developer", @"URL": @"u"}],
    [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"libobjc2", @"URL": @"u", @"Pin": @"stale"}],
    [[SWRepository alloc] initWithPlistEntry:@{@"Name": @"gershwin-workspace", @"URL": @"u"}],
  ];

  SWGitHubBuildStatus *buildStatus = [[SWGitHubBuildStatus alloc] initWithFetcher:^NSData *(NSURL *url) {
    return [@"{\"total_count\":1,\"check_runs\":[{\"status\":\"completed\",\"conclusion\":\"success\"}]}"
             dataUsingEncoding:NSUTF8StringEncoding];
  }];

  SWUpdateChecker *checker = [[SWUpdateChecker alloc] initWithSourcesDirectory:sourcesDir
                                                                    useDevBranch:NO
                                                                  gitToolFactory:nil
                                                               buildStatusClient:buildStatus
                                                                      logHandler:nil];

  __block NSArray *result = nil;
  __block BOOL reachableResult = NO;
  __block NSUInteger progressCalls = 0;
  [checker checkRepositories:entries
                stopRequested:nil
                     progress:^(SWRepository *r, NSUInteger i, NSUInteger t) { progressCalls++; }
                   completion:^(NSArray *repositoriesWithUpdates, BOOL anyReachable) {
    // completion's array is an ARC +1 temporary from SWUpdateChecker.m; this
    // test file is MRC (Testing.h's PASS macros retain/release manually), so
    // it must retain across the ARC/MRC boundary to keep it alive past this
    // call - a plain assignment here would leave a dangling pointer.
    result = [repositoriesWithUpdates retain];
    reachableResult = anyReachable;
  }];

  PASS(progressCalls == 3, "progress is reported once per repository");
  PASS(reachableResult, "at least one repository was reachable");
  PASS([checker localFailureReason] == nil,
       "a check that reached its remotes reports no local failure");
  PASS(result != nil, "completion received a result array");
  PASS([result count] == 2, "gershwin-developer has nothing to install; the other two do");

  SWRepository *libobjc2Result = nil, *workspaceResult = nil;
  for (SWRepository *r in result) {
    if ([[r name] isEqualToString:@"libobjc2"]) libobjc2Result = r;
    if ([[r name] isEqualToString:@"gershwin-workspace"]) workspaceResult = r;
  }

  PASS(libobjc2Result != nil, "libobjc2 is included: its pin advanced");
  PASS([libobjc2Result pinAdvanced], "libobjc2's pinAdvanced flag is set");
  PASS_EQUAL([libobjc2Result pin], newPinSha, "libobjc2's pin is updated to the incoming value");
  PASS([libobjc2Result selected], "an advanced pin with no build-status concept is selected by default");

  PASS(workspaceResult != nil, "gershwin-workspace is included: it has new commits");
  PASS([workspaceResult commitCount] == 2, "gershwin-workspace shows both new commits");
  PASS_EQUAL([workspaceResult targetBranch], @"main", "gershwin-workspace's target branch is main");
  PASS([workspaceResult buildStatus] == SWBuildStatusPassed,
       "gershwin-workspace's build status comes from the injected GitHub client");
  PASS([workspaceResult selected], "a passed-build repository with new commits is selected by default");

  [result release];
  runShell([NSString stringWithFormat:@"rm -rf %@", base]);
  [arp release];
  return 0;
}
