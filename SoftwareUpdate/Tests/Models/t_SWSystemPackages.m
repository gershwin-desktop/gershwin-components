/* t_SWSystemPackages.m - ObjectTesting coverage for SWSystemPackages: the
 * pkg output parsers, the pending-upgrade decision, the checker and the
 * upgrader with injected command runners (no pkg, no network), and the
 * synthetic list item they produce.
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWSystemPackages.h"
#import "SWRepository.h"
#import "SWSelectionRules.h"

static NSString *const kPkgVerbose =
  @"Version                 : 2.1.0\n"
  @"PKG_DBDIR = \"/var/db/pkg\";\n"
  @"Repositories:\n"
  @"  FreeBSD: { \n"
  @"    url             : \"pkg+https://pkg.FreeBSD.org/FreeBSD:15:amd64/latest\",\n"
  @"    enabled         : yes,\n"
  @"    priority        : 0,\n"
  @"    mirror_type     : \"SRV\",\n"
  @"    signature_type  : \"NONE\"\n"
  @"  }\n"
  @"  NextBSD: { \n"
  @"    url             : \"https://example.org/nextbsd-pkg/continuous-amd64\",\n"
  @"    enabled         : yes,\n"
  @"    priority        : 0,\n"
  @"    signature_type  : \"NONE\"\n"
  @"  }\n";

static NSString *const kManifest =
  @"{\"name\":\"NextBSD-kernel\",\"origin\":\"nextbsd/NextBSD-kernel\",\"version\":\"0.0.0.2\",\"comment\":\"k\"}\n"
  @"{\"name\":\"NextBSD-userland\",\"origin\":\"nextbsd/NextBSD-userland\",\"version\":\"0.0.0.2\"}\n"
  @"not json at all\n"
  @"{\"name\":\"NextBSD-contrib\",\"version\":\"0.0.0.1\"}\n";

static NSString *const kQuery =
  @"FreeBSD bash 5.2.37\n"
  @"NextBSD NextBSD-kernel 0.0.0.1\n"
  @"NextBSD NextBSD-userland 0.0.0.2\n"
  @"NextBSD NextBSD-contrib 0.0.0.1\n"
  @"NextBSD NextBSD-gone 0.0.0.1\n";

/* What `pkg version -t a b` would print, for the dotted test versions. */
static NSString *versionTestOutput(NSString *a, NSString *b)
{
  NSComparisonResult r = [a compare:b options:NSNumericSearch];
  return r == NSOrderedAscending ? @"<\n" : (r == NSOrderedDescending ? @">\n" : @"=\n");
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("pkg -vv repository URL")
  {
    PASS_EQUAL([SWSystemPackages repositoryURLFromPkgConfiguration:kPkgVerbose repositoryName:@"NextBSD"],
               @"https://example.org/nextbsd-pkg/continuous-amd64",
               "the url of the repository named NextBSD is found, not the first one");
    PASS_EQUAL([SWSystemPackages repositoryURLFromPkgConfiguration:kPkgVerbose repositoryName:@"FreeBSD"],
               @"https://pkg.FreeBSD.org/FreeBSD:15:amd64/latest",
               "the pkg+ SRV prefix is dropped, since fetch cannot resolve it");
    PASS([SWSystemPackages repositoryURLFromPkgConfiguration:kPkgVerbose repositoryName:@"Next"] == nil,
         "a name that is only a prefix of a repository does not match");
    PASS([SWSystemPackages repositoryURLFromPkgConfiguration:@"url : \"https://x\"\n" repositoryName:@"NextBSD"] == nil,
         "no Repositories section means no URL");
    PASS([SWSystemPackages repositoryURLFromPkgConfiguration:nil repositoryName:@"NextBSD"] == nil,
         "nil output means no URL");
  }
  END_SET("pkg -vv repository URL")

  START_SET("manifest and query parsers")
  {
    NSDictionary *remote = [SWSystemPackages packageVersionsFromManifest:kManifest];
    PASS([remote count] == 3, "every JSON line is read and a broken line is skipped");
    PASS_EQUAL([remote objectForKey:@"NextBSD-kernel"], @"0.0.0.2", "name and version are paired");

    NSDictionary *installed = [SWSystemPackages installedPackagesFromQueryOutput:kQuery
                                                                  repositoryName:@"NextBSD"];
    PASS([installed count] == 4, "only packages of the NextBSD repository are kept");
    PASS([installed objectForKey:@"bash"] == nil, "a package from another repository is ignored");
    PASS_EQUAL([installed objectForKey:@"NextBSD-kernel"], @"0.0.0.1", "installed version is read");
  }
  END_SET("manifest and query parsers")

  START_SET("pending upgrades")
  {
    NSDictionary *remote = [SWSystemPackages packageVersionsFromManifest:kManifest];
    NSDictionary *installed = [SWSystemPackages installedPackagesFromQueryOutput:kQuery
                                                                  repositoryName:@"NextBSD"];
    SWVersionComparator cmp = ^NSComparisonResult(NSString *a, NSString *b) {
      return [a compare:b options:NSNumericSearch];
    };
    NSArray *pending = [SWSystemPackages pendingUpgradesForInstalled:installed available:remote comparator:cmp];
    PASS([pending count] == 1, "only the package with a newer remote version is pending");
    SWSystemPackageUpgrade *up = [pending firstObject];
    PASS_EQUAL([up name], @"NextBSD-kernel", "it is the kernel");
    PASS_EQUAL([up displayLine], @"NextBSD-kernel 0.0.0.1 -> 0.0.0.2", "details line format");
    PASS([SWSystemPackages upgradesRequireRestart:pending], "a pending kernel package needs a restart");

    NSDictionary *userlandOnly = @{@"NextBSD-userland": @"0.0.0.1"};
    NSArray *noKernel = [SWSystemPackages pendingUpgradesForInstalled:userlandOnly available:remote comparator:cmp];
    PASS([noKernel count] == 1 && ![SWSystemPackages upgradesRequireRestart:noKernel],
         "userland alone does not need a restart");

    NSArray *none = [SWSystemPackages pendingUpgradesForInstalled:installed available:@{} comparator:cmp];
    PASS(none != nil && [none count] == 0, "an empty catalogue means nothing pending");

    NSDictionary *two = @{@"b-pkg": @"1", @"a-pkg": @"1"};
    NSDictionary *twoRemote = @{@"b-pkg": @"2", @"a-pkg": @"2"};
    NSArray *sorted = [SWSystemPackages pendingUpgradesForInstalled:two available:twoRemote comparator:cmp];
    PASS_EQUAL([[sorted firstObject] name], @"a-pkg", "pending upgrades are listed by name");
  }
  END_SET("pending upgrades")

  START_SET("checker with injected commands")
  {
    NSMutableArray *calls = [NSMutableArray array];
    __block NSString *queryOutput = kQuery;
    __block int fetchStatus = 0;
    SWCommandOutputRunner runner = ^NSString *(NSString *path, NSArray *args, int *status) {
      [calls addObject:[[path lastPathComponent] stringByAppendingFormat:@" %@",
                        [args componentsJoinedByString:@" "]]];
      *status = 0;
      if ([path isEqualToString:@"/usr/sbin/pkg"] && [[args firstObject] isEqualToString:@"-vv"]) return kPkgVerbose;
      if ([path isEqualToString:@"/usr/bin/fetch"]) { *status = fetchStatus; return @""; }
      if ([path isEqualToString:@"/usr/bin/tar"]) return kManifest;
      if ([path isEqualToString:@"/usr/sbin/pkg"] && [[args firstObject] isEqualToString:@"query"]) return queryOutput;
      if ([path isEqualToString:@"/usr/sbin/pkg"] && [[args firstObject] isEqualToString:@"version"])
        return versionTestOutput(args[2], args[3]);
      *status = 127;
      return nil;
    };
    NSMutableArray *logs = [NSMutableArray array];
    SWSystemPackageChecker *checker =
      [[[SWSystemPackageChecker alloc] initWithRepositoryName:@"NextBSD"
                                                commandRunner:runner
                                                   logHandler:^(NSString *l) { [logs addObject:l]; }] autorelease];
    NSArray *pending = [checker pendingUpgrades];
    PASS([pending count] == 1 && [[[pending firstObject] name] isEqualToString:@"NextBSD-kernel"],
         "the checker finds the pending kernel through pkg version -t");

    BOOL fetchedRightURL = NO, queried = NO;
    for (NSString *c in calls) {
      if ([c hasPrefix:@"fetch "] && [c hasSuffix:@" https://example.org/nextbsd-pkg/continuous-amd64/packagesite.pkg"])
        fetchedRightURL = YES;
      if ([c isEqualToString:@"pkg query %R %n %v"]) queried = YES;
    }
    PASS(fetchedRightURL, "packagesite.pkg is downloaded from the URL pkg -vv names");
    PASS(queried, "installed packages come from pkg query '%%R %%n %%v'");

    fetchStatus = 1;
    [logs removeAllObjects];
    PASS([checker pendingUpgrades] == nil, "a failed download makes the item not appear");
    PASS([logs count] > 0, "and says why in the log");

    fetchStatus = 0;
    __block BOOL garbleVersion = YES;
    SWCommandOutputRunner garbling = ^NSString *(NSString *path, NSArray *args, int *status) {
      if (garbleVersion && [[args firstObject] isEqualToString:@"version"]) { *status = 0; return @"?\n"; }
      return runner(path, args, status);
    };
    SWSystemPackageChecker *garbled =
      [[[SWSystemPackageChecker alloc] initWithRepositoryName:@"NextBSD"
                                                commandRunner:garbling
                                                   logHandler:nil] autorelease];
    PASS([garbled pendingUpgrades] == nil, "an unreadable pkg version -t answer is a failed check, not 'up to date'");

    fetchStatus = 0;
    queryOutput = @"FreeBSD bash 5\n";
    NSArray *empty = [checker pendingUpgrades];
    PASS(empty != nil && [empty count] == 0, "nothing installed from the repository means nothing pending");
  }
  END_SET("checker with injected commands")

  START_SET("upgrader with injected commands")
  {
    NSMutableArray *calls = [NSMutableArray array];
    __block NSUInteger lockedFailuresLeft = 1;
    __block int upgradeStatus = 0;
    __block NSString *seenAssumeYes = nil;
    SWStreamingCommandRunner runner = ^int(NSString *path, NSArray *args, NSDictionary *env,
                                            void (^lineHandler)(NSString *)) {
      [calls addObject:[args componentsJoinedByString:@" "]];
      seenAssumeYes = [env objectForKey:@"ASSUME_ALWAYS_YES"];
      if ([[args firstObject] isEqualToString:@"update"] && lockedFailuresLeft > 0) {
        lockedFailuresLeft--;
        lineHandler(@"pkg: sqlite error ... database is locked");
        return 1;
      }
      if ([[args firstObject] isEqualToString:@"upgrade"]) return upgradeStatus;
      return 0;
    };
    SWSystemPackageUpgrader *upgrader =
      [[[SWSystemPackageUpgrader alloc] initWithCommandRunner:runner logHandler:nil] autorelease];
    [upgrader setLockRetryDelay:0];
    NSString *error = nil;
    BOOL ok = [upgrader upgradeWithStepHandler:nil error:&error];
    PASS(ok, "a locked database is waited out, then the upgrade succeeds");
    NSArray *want = @[ @"update -r NextBSD", @"update -r NextBSD", @"upgrade -y -r NextBSD" ];
    PASS_EQUAL(calls, want,
      "pkg update is retried, then pkg upgrade -y runs, both on the NextBSD repository only");
    PASS_EQUAL(seenAssumeYes, @"yes", "ASSUME_ALWAYS_YES=yes is set for pkg");

    [calls removeAllObjects];
    upgradeStatus = 1;
    error = nil;
    ok = [upgrader upgradeWithStepHandler:nil error:&error];
    PASS(!ok && [error rangeOfString:@"pkg upgrade"].location != NSNotFound,
         "a failing pkg upgrade fails the run and names the command");
    PASS([calls count] == 2, "a plain failure is not retried");

    [calls removeAllObjects];
    lockedFailuresLeft = 100;
    ok = [upgrader upgradeWithStepHandler:nil error:&error];
    PASS(!ok && [calls count] == [upgrader maxLockAttempts], "a lock that never clears gives up");
  }
  END_SET("upgrader with injected commands")

  START_SET("list item")
  {
    SWSystemPackageUpgrade *k = [[[SWSystemPackageUpgrade alloc] init] autorelease];
    [k setName:@"NextBSD-kernel"]; [k setInstalledVersion:@"1"]; [k setAvailableVersion:@"2"];
    NSArray *ups = @[ k ];
    SWRepository *item = [SWRepository systemPackagesItemNamed:@"NextBSD" upgrades:ups];
    PASS([item isSystemPackages], "the item is marked as system packages");
    PASS_EQUAL([item name], @"NextBSD", "named after the OS");
    PASS([item hasUpdate], "pending upgrades are an update");
    PASS([item restartRequired], "a kernel upgrade requires a restart");
    PASS(![item isPinned] && [item isReachable], "neither pinned nor unreachable");
    PASS([SWSelectionRules blockedReasonForRepository:item] == nil, "never blocked by a server build");
    PASS([SWSelectionRules canToggleRepository:item force:NO], "the user may untick it");
    [item setSelected:NO];
    NSArray *one = @[ item ];
    [SWSelectionRules applyDefaultSelectionToRepositories:one];
    PASS([item selected], "selected by default");

    SWRepository *nothing = [SWRepository systemPackagesItemNamed:@"NextBSD" upgrades:@[]];
    PASS(![nothing hasUpdate], "no pending upgrades means no update");
  }
  END_SET("list item")

  [arp release];
  return 0;
}
