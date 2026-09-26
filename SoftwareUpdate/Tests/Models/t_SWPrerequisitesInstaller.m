/* t_SWPrerequisitesInstaller.m - ObjectTesting coverage for
 * SWPrerequisitesInstaller. Headless; the package manager backend is a
 * local mock, so no real package manager runs.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWPrerequisitesInstaller.h"
#import <PackageManager/GWPackageManagerBackend.h>
#include <unistd.h>

#pragma mark - Mock backend

@interface MockPrereqBackend : NSObject <GWPackageManagerBackend>
{
  NSMutableArray<NSString *> *_installedPackages;
  NSMutableArray<NSString *> *_installCalls;
  NSString *_failPackage;
}
@property (readonly) NSString *backendName;
- (void)setInstalledPackages:(NSArray<NSString *> *)names;
- (void)setFailPackage:(NSString *)name;
@property (readonly) NSArray<NSString *> *installCalls;
@end

@implementation MockPrereqBackend

- (instancetype)init
{
  self = [super init];
  if (self) {
    _installedPackages = [NSMutableArray array];
    _installCalls = [NSMutableArray array];
  }
  return self;
}

- (NSString *)backendName { return @"MockPrereqBackend"; }
- (void)setInstalledPackages:(NSArray<NSString *> *)names { _installedPackages = [names mutableCopy]; }
- (void)setFailPackage:(NSString *)name { _failPackage = name; }
- (NSArray<NSString *> *)installCalls { return [_installCalls copy]; }

- (BOOL)isPackageInstalled:(NSString *)packageName
{
  return [_installedPackages containsObject:packageName];
}

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
             progress:(id<GWInstallProgressHandler>)progressHandler
                error:(NSError **)error
{
  [_installCalls addObjectsFromArray:packageNames];
  if ([packageNames containsObject:_failPackage]) {
    if (error) {
      *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorCommandFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"mock install failure"}];
    }
    return NO;
  }
  [_installedPackages addObjectsFromArray:packageNames];
  return YES;
}

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                progress:(id<GWInstallProgressHandler>)progressHandler
                   error:(NSError **)error
{
  return YES;
}

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error { return @[]; }
- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error { return nil; }

@end

#pragma mark - Helpers

static NSString *writeOSSupportFile(NSString *dir, NSString *osID, NSString *contents)
{
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *path = [dir stringByAppendingPathComponent:
    [osID stringByAppendingPathExtension:@"txt"]];
  [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  return path;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *osSupportDir = [NSString stringWithFormat:@"/tmp/sw-prereq-test-%d", getpid()];

  /* --- declaredPackages: comments and blank lines are stripped --- */
  {
    writeOSSupportFile(osSupportDir, @"debian",
      @"freerdp2-x11 # for RemoteDesktop\n\ncups\n  \nsane-utils\n");

    SWPrerequisitesInstaller *installer =
      [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDir
                                                      packageManager:nil
                                                       osIdentifier:@"debian"];
    NSArray *want = @[@"freerdp2-x11", @"cups", @"sane-utils"];
    PASS([[installer declaredPackages] isEqualToArray:want],
         "comments and blank lines are stripped from the package list, order preserved");
  }

  /* --- declaredPackages: no list for this OS returns nil, not an error --- */
  {
    SWPrerequisitesInstaller *installer =
      [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDir
                                                      packageManager:nil
                                                       osIdentifier:@"totally-unknown-os"];
    PASS([installer declaredPackages] == nil, "an OS with no package list returns nil, not an error");
  }

  /* --- installMissingPackagesWithProgress: only missing packages install --- */
  {
    writeOSSupportFile(osSupportDir, @"arch", @"freerdp\ncups\nsane\n");
    MockPrereqBackend *backend = [[MockPrereqBackend alloc] init];
    [backend setInstalledPackages:@[@"cups"]];
    GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:backend];

    SWPrerequisitesInstaller *installer =
      [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDir
                                                      packageManager:pm
                                                       osIdentifier:@"arch"];

    NSArray *wantMissing = @[@"freerdp", @"sane"];
    PASS([[installer missingPackages] isEqualToArray:wantMissing],
         "missingPackages excludes the already-installed package, preserving order");

    __block NSMutableArray *progressed = [NSMutableArray array];
    NSError *error = nil;
    BOOL ok = [installer installMissingPackagesWithProgress:^(NSString *name, NSUInteger i, NSUInteger t) {
      [progressed addObject:name];
    } error:&error];

    PASS(ok, "install succeeds when every missing package installs cleanly");
    PASS(error == nil, "no error on success");
    NSArray *wantInstalled = @[@"freerdp", @"sane"];
    PASS([[backend installCalls] isEqualToArray:wantInstalled],
         "only the missing packages (not the already-installed one) are installed, in list order");
    PASS([progressed isEqualToArray:wantInstalled],
         "progress is reported once per missing package, in the same order");
  }

  /* --- nothing missing: the phase completes without touching the backend --- */
  {
    writeOSSupportFile(osSupportDir, @"freebsd", @"pkg-a\npkg-b\n");
    MockPrereqBackend *backend = [[MockPrereqBackend alloc] init];
    [backend setInstalledPackages:@[@"pkg-a", @"pkg-b"]];
    GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:backend];

    SWPrerequisitesInstaller *installer =
      [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDir
                                                      packageManager:pm
                                                       osIdentifier:@"freebsd"];
    __block NSUInteger progressCalls = 0;
    BOOL ok = [installer installMissingPackagesWithProgress:^(NSString *n, NSUInteger i, NSUInteger t) {
      progressCalls++;
    } error:NULL];

    PASS(ok, "nothing missing succeeds immediately");
    PASS(progressCalls == 0, "no progress callbacks when nothing is missing");
    PASS([[backend installCalls] count] == 0, "the backend's install method is never called");
  }

  /* --- a failed install stops before touching later packages --- */
  {
    writeOSSupportFile(osSupportDir, @"openbsd", @"first\nsecond\nthird\n");
    MockPrereqBackend *backend = [[MockPrereqBackend alloc] init];
    [backend setFailPackage:@"second"];
    GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:backend];

    SWPrerequisitesInstaller *installer =
      [[SWPrerequisitesInstaller alloc] initWithOSSupportDirectory:osSupportDir
                                                      packageManager:pm
                                                       osIdentifier:@"openbsd"];
    NSError *error = nil;
    BOOL ok = [installer installMissingPackagesWithProgress:nil error:&error];

    PASS(!ok, "a failed package install reports failure");
    PASS(error != nil, "an error is returned naming the failure");
    NSArray *wantAttempted = @[@"first", @"second"];
    PASS([[backend installCalls] isEqualToArray:wantAttempted],
         "the run stops at the failing package - third is never attempted");
  }

  [[NSFileManager defaultManager] removeItemAtPath:osSupportDir error:NULL];
  [arp release];
  return 0;
}
