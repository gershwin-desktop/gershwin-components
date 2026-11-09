/* t_SWRepositoryList.m - ObjectTesting coverage for SWRepositoryList/SWRepository.
 * Headless.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWRepository.h"
#import "SWRepositoryList.h"

static NSString *const kFixtureCSV =
  @"# a comment line, and a blank line below should both be ignored\n"
  @"\n"
  @"Name,URL,Pin,RestartRequired\n"
  @"gershwin-developer,https://example.invalid/gershwin-developer.git,,\n"
  @"libobjc2,https://example.invalid/libobjc2.git,abc1234,\n"
  @"gershwin-windowmanager,https://example.invalid/gershwin-windowmanager.git,,YES\n";

/* The optional fifth column, Platforms, limits a repository to Windows builds
 * ("windows"), to everything else ("unix") or lists both. */
static NSString *const kPlatformCSV =
  @"Name,URL,Pin,RestartRequired,Platforms\n"
  @"libs-gui,https://example.invalid/libs-gui.git,abc1234,YES\n"
  @"plugins-themes-WinUXTheme,https://example.invalid/winux.git,92ab1fb,,windows\n"
  @"only-unix,https://example.invalid/u.git,,,unix\n"
  @"both,https://example.invalid/b.git,,,windows unix\n"
  @"gershwin-workspace,https://example.invalid/ws.git,,\n";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- a repository for Windows builds only is not Software Update's
   *     business anywhere else: it is never checked out there, so it could
   *     only be reported as a repository that could not be checked --- */
  {
    NSData *data = [kPlatformCSV dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *repos = [SWRepositoryList repositoriesFromCSVData:data error:NULL];
    NSMutableArray *names = [NSMutableArray array];
    for (SWRepository *r in repos) [names addObject:[r name]];

#ifdef _WIN32
    BOOL windows = YES;
#else
    BOOL windows = NO;
#endif
    PASS([names containsObject:@"plugins-themes-WinUXTheme"] == windows,
         "a Windows-only repository is listed in Windows builds and nowhere else");
    PASS([names containsObject:@"only-unix"] == !windows,
         "a repository for everything but Windows is not listed in Windows builds");
    PASS([names containsObject:@"both"], "a repository for both is listed everywhere");
    PASS([names containsObject:@"libs-gui"], "a row without a Platforms column is listed everywhere");
    PASS([names containsObject:@"gershwin-workspace"], "a row with an empty Platforms column is listed everywhere");
  }

  /* --- parsing a fixture CSV from data --- */
  {
    NSData *data = [kFixtureCSV dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSArray *repos = [SWRepositoryList repositoriesFromCSVData:data error:&error];

    PASS(repos != nil, "fixture CSV parses without error");
    PASS([repos count] == 3, "fixture CSV yields 3 repositories");

    SWRepository *first = [repos objectAtIndex:0];
    PASS_EQUAL([first name], @"gershwin-developer", "first repo name preserved");
    PASS(![first isPinned], "gershwin-developer has no pin");
    PASS(![first restartRequired], "gershwin-developer does not require a restart");

    SWRepository *second = [repos objectAtIndex:1];
    PASS_EQUAL([second name], @"libobjc2", "second repo name preserved");
    PASS([second isPinned], "libobjc2 is pinned");
    PASS_EQUAL([second pin], @"abc1234", "libobjc2 pin value read correctly");

    SWRepository *third = [repos objectAtIndex:2];
    PASS_EQUAL([third name], @"gershwin-windowmanager", "third repo name preserved");
    PASS([third restartRequired], "gershwin-windowmanager requires a restart");

    /* Order must be preserved exactly as listed - never re-sorted. */
    NSArray *names = [repos valueForKey:@"name"];
    NSArray *want = @[@"gershwin-developer", @"libobjc2", @"gershwin-windowmanager"];
    PASS([names isEqualToArray:want], "repository order is preserved as listed");
  }

  /* --- a repository with no explicit selection state defaults to unselected,
   * new commits empty, unknown build status: the check step fills these in,
   * not the CSV reader --- */
  {
    NSData *data = [kFixtureCSV dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *repos = [SWRepositoryList repositoriesFromCSVData:data error:NULL];
    SWRepository *first = [repos objectAtIndex:0];

    PASS(![first selected], "a freshly parsed repository is not selected");
    PASS([first commitCount] == 0, "a freshly parsed repository has no commits yet");
    PASS([first buildStatus] == SWBuildStatusUnknown,
         "a freshly parsed repository has unknown build status");
    PASS([first isReachable], "a freshly parsed repository is reachable until told otherwise");
  }

  /* --- marking a repository unreachable (fetch failed) --- */
  {
    NSData *data = [kFixtureCSV dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *repos = [SWRepositoryList repositoriesFromCSVData:data error:NULL];
    SWRepository *first = [repos objectAtIndex:0];

    [first setUnreachableReason:@"Couldn't check"];
    PASS(![first isReachable], "setting an unreachable reason makes the repo unreachable");
  }

  /* --- malformed data is reported, not thrown --- */
  {
    NSData *garbage = [@"this is not a csv file at all\nno commas anywhere in it\n"
                        dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSArray *repos = [SWRepositoryList repositoriesFromCSVData:garbage error:&error];

    PASS(repos == nil, "malformed data yields no repositories");
    PASS(error != nil, "malformed data reports an error rather than raising");
    PASS([[error domain] isEqualToString:SWRepositoryListErrorDomain],
         "error carries the SWRepositoryList error domain");
  }

  /* --- reading a nonexistent file path reports an error --- */
  {
    NSError *error = nil;
    NSArray *repos = [SWRepositoryList repositoriesFromCSVAtPath:@"/nonexistent/Repositories.csv"
                                                            error:&error];
    PASS(repos == nil, "a missing file yields no repositories");
    PASS(error != nil, "a missing file reports an error");
    PASS([error code] == SWRepositoryListErrorFileNotFound,
         "a missing file reports the FileNotFound error code");
  }

  /* --- reading the real gershwin-developer Repositories.csv, when present --- */
  {
    NSString *realPath = @"/Developer/Library/Repositories.csv";
    if ([[NSFileManager defaultManager] fileExistsAtPath:realPath]) {
      NSError *error = nil;
      NSArray *repos = [SWRepositoryList repositoriesFromCSVAtPath:realPath error:&error];

      PASS(repos != nil, "the real Repositories.csv parses without error");
      PASS([repos count] > 0, "the real Repositories.csv yields at least one repository");
      PASS_EQUAL([[repos objectAtIndex:0] name], @"gershwin-developer",
                 "gershwin-developer is always first, per the spec's stated order");

      SWRepository *last = [repos lastObject];
      PASS_EQUAL([last name], @"gershwin-desktop.wiki",
                 "the wiki is the last entry, matching checkout.sh's original order");
    }
  }

  [arp release];
  return 0;
}
