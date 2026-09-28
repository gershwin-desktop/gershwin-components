/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageManager Test Suite
 *
 * Comprehensive unit tests for the GWPackageManager framework.
 * Tests are standalone; uses a simple assertion framework.
 *
 * Test categories:
 *   - GWOSDetector tests
 *   - GWPackageInstallSpec tests
 *   - Backend tests (with mocked executor)
 *   - GWPackageManager tests (with mocked backend)
 */

#import <Foundation/Foundation.h>
#import "GWOSDetector.h"
#import "GWPackageInstallSpec.h"
#import "GWSystemCommandExecutor.h"
#import "GWPackageManagerBackend.h"
#import "GWPackageManager.h"
#import "GWHeaderDatabase.h"
#import "GWDebBackend.h"
#import "GWSudoHelper.h"
#import "GWAppImageDownloader.h"
#import "GWAppImageAssetPicker.h"
#import "GWCurlMeterReader.h"

/* The key a Dependencies.plist uses for "any system with this kernel",
 * which is what dependencySearchOrder falls back to last. */
#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__)
static NSString * const kKernelKey = @"freebsd";
#elif defined(__OpenBSD__)
static NSString * const kKernelKey = @"openbsd";
#elif defined(__NetBSD__)
static NSString * const kKernelKey = @"netbsd";
#else
static NSString * const kKernelKey = @"linux";
#endif

#pragma mark - Test Assertion Framework

static int testCount = 0;
static int passCount = 0;
static int failCount = 0;

#define TAssert(condition, desc, ...) \
  do { \
    testCount++; \
    if (!(condition)) { \
      failCount++; \
      NSLog(@"  FAIL: %s:%d - " desc, __FILE__, __LINE__, ##__VA_ARGS__); \
      return NO; \
    } \
  } while(0)

#define TAssertEqualObjects(a, b, desc, ...) \
  do { \
    testCount++; \
    id _a = (a); id _b = (b); \
    if (_a != _b && ![_a isEqual:_b]) { \
      failCount++; \
      NSLog(@"  FAIL: %s:%d - " desc " (got '%@', expected '%@')", \
            __FILE__, __LINE__, ##__VA_ARGS__, _a, _b); \
      return NO; \
    } \
  } while(0)

#define TAssertTrue(condition, desc, ...) \
  TAssert((condition), desc, ##__VA_ARGS__)

#define TAssertFalse(condition, desc, ...) \
  TAssert(!(condition), desc, ##__VA_ARGS__)

#define TAssertNotNil(obj, desc, ...) \
  TAssert((obj) != nil, desc, ##__VA_ARGS__)

#define TAssertNil(obj, desc, ...) \
  TAssert((obj) == nil, desc, ##__VA_ARGS__)

static void runTest(NSString *name, BOOL (^block)(void))
{
  @autoreleasepool
    {
      NSLog(@"\n--- %@ ---", name);
      BOOL result = block();
      if (result)
        {
          passCount++;
          NSLog(@"  PASS");
        }
      else
        {
          NSLog(@"  FAILED");
        }
    }
}

/* The asset-picker cases live in their own file, but they are compiled INTO
 * this tool rather than linked beside it: they use the TAssert macros
 * above, and those expand to a `return NO` that only means anything inside a
 * function this file owns. Included here, after the macros and this runner
 * exist, and deliberately not added to OBJC_FILES. */
void AGRegisterAppImageAssetPickerTests(void);
#include "AGAppImageAssetPickerTests.m"

/* The download.kde.org resolver, the same arrangement: its cases are a
 * function this file owns, and the recorded index pages it parses live in
 * Tests/kdefixtures (see the README there). */
void AGRegisterKDEAppImagePickerTests(void);
#include "GWKDEAppImagePickerTests.m"

#pragma mark - Mock Objects

#pragma mark Mock Command Executor

@interface GWMockSystemCommandExecutor : NSObject <GWSystemCommandExecutor>
{
  NSMutableArray<NSDictionary *> *_recordedCalls;
  NSMutableDictionary *_resultMap; // key -> NSDictionary with exitCode, stdout, stderr
}
@property (readonly) NSArray<NSDictionary *> *recordedCalls;
- (void)setResultForCommand:(NSString *)path
                  arguments:(NSArray *)args
                   exitCode:(int)exitCode
                     output:(NSString *)output
               errorOutput:(NSString *)errorOutput;
- (void)clearResults;
@end

@implementation GWMockSystemCommandExecutor

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _recordedCalls = [NSMutableArray array];
      _resultMap = [NSMutableDictionary dictionary];
    }
  return self;
}

- (NSString *)_keyForPath:(NSString *)path arguments:(NSArray *)args
{
  return [NSString stringWithFormat:@"%@ %@", path, [args componentsJoinedByString:@" "]];
}

- (void)setResultForCommand:(NSString *)path
                  arguments:(NSArray *)args
                   exitCode:(int)exitCode
                     output:(NSString *)output
               errorOutput:(NSString *)errorOutput
{
  NSString *key = [self _keyForPath:path arguments:args];
  NSDictionary *result = @{
    @"exitCode": @(exitCode),
    @"output": output ?: @"",
    @"errorOutput": errorOutput ?: @"",
  };
  _resultMap[key] = result;
}

- (void)clearResults
{
  [_recordedCalls removeAllObjects];
  [_resultMap removeAllObjects];
}

- (NSArray *)recordedCalls
{
  return [_recordedCalls copy];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
{
  return [self execute:path arguments:args output:nil errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
{
  return [self execute:path arguments:args output:output errorOutput:nil];
}

- (int)execute:(NSString *)path arguments:(NSArray *)args
        output:(NSString *__autoreleasing *)output
  errorOutput:(NSString *__autoreleasing *)errorOutput
{
  NSString *key = [self _keyForPath:path arguments:args];
  NSDictionary *result = _resultMap[key];

  [_recordedCalls addObject:@{
    @"path": path ?: @"",
    @"args": args ?: @[],
  }];

  if (output)
    *output = result[@"output"] ?: @"";
  if (errorOutput)
    *errorOutput = result[@"errorOutput"] ?: @"";

  return [result[@"exitCode"] intValue];
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stderrCallback:(void (^)(NSString *line))callback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  // Delegate to the existing output-capturing variant
  NSString *captured = nil;
  int rc = [self execute:path arguments:args output:nil errorOutput:&captured];
  if (errorOutput) *errorOutput = captured ?: @"";
  // Call the callback with the captured output as a single line
  if (callback && [captured length] > 0)
    callback(captured);
  return rc;
}

- (int)execute:(NSString *)path
     arguments:(NSArray *)args
 stdoutCallback:(void (^)(NSString *line))stdoutCallback
 stderrCallback:(void (^)(NSString *line))stderrCallback
 capturedErrorOutput:(NSString *__autoreleasing *)errorOutput
{
  // Delegate to the variant that captures error output, ignore stdout
  return [self execute:path arguments:args stderrCallback:stderrCallback capturedErrorOutput:errorOutput];
}

@end

#pragma mark Mock Backend

@interface GWMockPackageManagerBackend : NSObject <GWPackageManagerBackend>
{
  NSMutableArray<NSDictionary *> *_recordedCalls;
  BOOL _installResult;
  BOOL _uninstallResult;
  NSError *_installError;
  NSError *_uninstallError;
  NSArray *_filesResult;
  NSString *_owningFileResult;
  NSSet *_installedPackageNames;
}
@property (readonly) NSArray<NSDictionary *> *recordedCalls;
@property (readonly) NSString *backendName;
- (void)setInstallResult:(BOOL)result error:(NSError *)error;
- (void)setUninstallResult:(BOOL)result error:(NSError *)error;
- (void)setFilesResult:(NSArray *)files;
- (void)setOwningFileResult:(NSString *)path;
- (void)setInstalledPackageNames:(NSArray<NSString *> *)names;
- (void)clearResults;
@end

@implementation GWMockPackageManagerBackend

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _recordedCalls = [NSMutableArray array];
      _installResult = YES;
      _uninstallResult = YES;
    }
  return self;
}

- (NSString *)backendName { return @"MockBackend"; }

- (void)setInstallResult:(BOOL)result error:(NSError *)error
{
  _installResult = result;
  _installError = error;
}

- (void)setUninstallResult:(BOOL)result error:(NSError *)error
{
  _uninstallResult = result;
  _uninstallError = error;
}

- (void)setFilesResult:(NSArray *)files { _filesResult = files; }
- (void)setOwningFileResult:(NSString *)path { _owningFileResult = path; }
- (void)setInstalledPackageNames:(NSArray<NSString *> *)names
{
  _installedPackageNames = names ? [NSSet setWithArray:names] : nil;
}

- (void)clearResults { [_recordedCalls removeAllObjects]; }

- (NSArray *)recordedCalls { return [_recordedCalls copy]; }

- (BOOL)isPackageInstalled:(NSString *)packageName
{
  [_recordedCalls addObject:@{
    @"method": @"isPackageInstalled:",
    @"packageName": packageName ?: @"",
  }];
  return [_installedPackageNames containsObject:packageName];
}

- (BOOL)installPackages:(NSArray *)packageNames
        localFilePaths:(NSArray *)filePaths
             progress:(id<GWInstallProgressHandler>)handler
                error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"installPackages:localFilePaths:progress:error:",
    @"packages": packageNames ?: @[],
    @"localFilePaths": filePaths ?: @[],
    @"handler": handler ? (id)handler : [NSNull null],
  }];

  if (handler)
    {
      [handler installDidProgress:0.0 message:@"Preparing..."];
      [handler installDidProgress:0.5 message:@"Installing packages..."];
    }

  if (error && _installError)
    *error = _installError;

  if (!_installResult && _installError == nil)
    {
      if (error)
        *error = [NSError errorWithDomain:@"GWPackageManagerErrorDomain"
                                    code:GWPackageManagerErrorCommandFailed
                                userInfo:@{NSLocalizedDescriptionKey: @"Mock install failed"}];
    }

  return _installResult;
}

- (BOOL)uninstallPackages:(NSArray *)packageNames
                progress:(id<GWInstallProgressHandler>)handler
                   error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"uninstallPackages:progress:error:",
    @"packages": packageNames ?: @[],
    @"handler": handler ? (id)handler : [NSNull null],
  }];

  if (handler)
    {
      [handler installDidProgress:0.0 message:@"Preparing..."];
      [handler installDidProgress:0.5 message:@"Uninstalling packages..."];
    }

  if (error && _uninstallError)
    *error = _uninstallError;

  return _uninstallResult;
}

- (NSArray *)filesForPackage:(NSString *)name error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"filesForPackage:error:",
    @"package": name ?: @"",
  }];
  return _filesResult ?: @[];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  [_recordedCalls addObject:@{
    @"method": @"packageOwningFile:error:",
    @"path": path ?: @"",
  }];
  return _owningFileResult;
}

@end

#pragma mark Mock Progress Handler

@interface GWMockProgressHandler : NSObject <GWInstallProgressHandler>
{
  NSMutableArray *_progressCalls;
  NSMutableArray *_outputLines;
}
@property (readonly) NSArray *progressCalls;
@property (readonly) NSArray *outputLines;
@end

@implementation GWMockProgressHandler

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _progressCalls = [NSMutableArray array];
      _outputLines = [NSMutableArray array];
    }
  return self;
}

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  [_progressCalls addObject:@{
    @"progress": @(progress),
    @"message": message ?: @"",
  }];
}

- (void)installDidOutputLine:(NSString *)line
{
  [_outputLines addObject:line ?: @""];
}

- (NSArray *)progressCalls { return [_progressCalls copy]; }
- (NSArray *)outputLines { return [_outputLines copy]; }

@end

#pragma mark - GWOSDetector Tests

@interface GWOSDetectorTestHelper : NSObject
+ (BOOL)testFreeBSDWithOSRelease;
+ (BOOL)testFreeBSDWithoutOSReleaseFallbackToUname;
+ (BOOL)testLinuxWithOSRelease;
+ (BOOL)testLinuxMultipleIDLike;
+ (BOOL)testDependencySearchOrderPerDistribution;
+ (BOOL)testDependencySearchOrderFamilyBeforeKernel;
+ (BOOL)testInstallSpecPicksDistributionPackages;
+ (BOOL)testInstallSpecFallsBackToKernelEntry;
+ (BOOL)testOpenBSDWithoutOSRelease;
@end

@implementation GWOSDetectorTestHelper

+ (BOOL)testFreeBSDWithOSRelease
{
  // Create temp os-release file with GhostBSD-like content
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-ghostbsd"];
  NSString *content = @"ID=ghostbsd\nID_LIKE=freebsd\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:@"FreeBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"ghostbsd", @"Primary OS ID should be 'ghostbsd'");
  TAssertEqualObjects(searchOrder, (@[@"ghostbsd", @"freebsd"]),
                      @"Search order should be [ghostbsd, freebsd]");

  // Cleanup
  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

+ (BOOL)testFreeBSDWithoutOSReleaseFallbackToUname
{
  // Use a non-existent path
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  [GWOSDetector setUnameOverride:@"FreeBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"freebsd", @"Should fall back to 'freebsd' from uname");

  // On fallback, search order should just be the primary ID
  TAssertEqualObjects(searchOrder, (@[@"freebsd"]),
                      @"Search order should be [freebsd] on uname fallback");

  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

+ (BOOL)testLinuxWithOSRelease
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-debian"];
  NSString *content = @"ID=debian\nID_LIKE=\nVERSION_ID=\"12\"\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"debian", @"Primary OS ID should be 'debian'");
  // When ID_LIKE is empty, search order should be just the primary
  TAssertEqualObjects(searchOrder, (@[@"debian"]),
                      @"Search order should be [debian] with empty ID_LIKE");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testLinuxMultipleIDLike
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-ubuntu"];
  NSString *content = @"ID=ubuntu\nID_LIKE=\"ubuntu debian\"\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *osID = [GWOSDetector currentOSIdentifier];
  NSArray *searchOrder = [GWOSDetector osSearchOrder];

  TAssertEqualObjects(osID, @"ubuntu", @"Primary OS ID should be 'ubuntu'");
  TAssertEqualObjects(searchOrder, (@[@"ubuntu", @"ubuntu", @"debian"]),
                      @"Search order should include both ID_LIKE values");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testDependencySearchOrderPerDistribution
{
  // The package names differ per distribution (Arch calls the profiler
  // "perf", Debian "linux-perf"), so the distribution must be asked first
  // and the kernel only last.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-arch"];
  NSString *content = @"ID=arch\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSArray *order = [GWOSDetector dependencySearchOrder];

  TAssertEqualObjects([order firstObject], @"arch",
                      @"The distribution itself must be asked first");
  TAssert([order containsObject:kKernelKey],
          @"The kernel must be the shared fallback, got %@", order);
  TAssert([order indexOfObject:kKernelKey] == [order count] - 1,
          @"The kernel must come last, got %@", order);

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testDependencySearchOrderFamilyBeforeKernel
{
  // A derivative falls back to the distribution it is built on, and on to
  // the package-manager family, before the kernel entry is reached.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-mint"];
  NSString *content = @"ID=linuxmint\nID_LIKE=ubuntu\n";
  [content writeToFile:osReleasePath atomically:YES encoding:NSUTF8StringEncoding error:nil];

  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSArray *order = [GWOSDetector dependencySearchOrder];
  NSArray *expected = @[@"linuxmint", @"ubuntu", @"debian", kKernelKey];

  TAssertEqualObjects(order, expected,
                      @"Order should be distribution, ID_LIKE, family, kernel");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testInstallSpecPicksDistributionPackages
{
  // The bug this guards against: on Arch the shared "linux" entry offered
  // the Debian package name linux-perf, which does not exist there.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-arch-spec"];
  [@"ID=arch\n" writeToFile:osReleasePath atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-distro.plist"];
  NSDictionary *plist = @{
    @"packages": @[],
    @"os_overrides": @{
      @"debian": @{@"packages": @[@"linux-perf"]},
      @"arch": @{@"packages": @[@"perf"]},
      @"linux": @{@"packages": @[]},
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse the plist");
  TAssertEqualObjects(spec.packages, @[@"perf"],
                      @"Arch must get its own package name");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testInstallSpecFallsBackToKernelEntry
{
  // A plist that names one set of packages for every Linux distribution
  // must still be found on a distribution that has no entry of its own.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"os-release-test-arch-kernel"];
  [@"ID=arch\n" writeToFile:osReleasePath atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
  [GWOSDetector setOSReleasePathOverride:osReleasePath];
  [GWOSDetector setUnameOverride:nil];

  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-kernel.plist"];
  NSDictionary *plist = @{
    @"packages": @[],
    @"os_overrides": @{
      kKernelKey: @{@"packages": @[@"shared-for-this-kernel"]},
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse the plist");
  TAssertEqualObjects(spec.packages, @[@"shared-for-this-kernel"],
                      @"The kernel entry must be the last fallback");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];

  return YES;
}

+ (BOOL)testOpenBSDWithoutOSRelease
{
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  [GWOSDetector setUnameOverride:@"OpenBSD"];

  NSString *osID = [GWOSDetector currentOSIdentifier];

  TAssertEqualObjects(osID, @"openbsd", @"Should fall back to 'openbsd' from uname");

  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];

  return YES;
}

@end

#pragma mark - GWPackageInstallSpec Tests

@interface GWPackageInstallSpecTestHelper : NSObject
+ (BOOL)testInstallSpecNoOverrides;
+ (BOOL)testInstallSpecOSOverride;
+ (BOOL)testInstallSpecPartialOverride;
+ (BOOL)testUninstallSpecBasic;
+ (BOOL)testUninstallSpecOverride;
@end

@implementation GWPackageInstallSpecTestHelper

+ (BOOL)testInstallSpecNoOverrides
{
  // Write a plist without overrides
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-null.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp", @"gimp-plugins"],
    @"postinstall_command": @"/usr/local/bin/gimp",
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse plist without overrides");
  TAssertNil(error, @"Should not produce an error");
  TAssertEqualObjects(spec.packages, (@[@"gimp", @"gimp-plugins"]),
                      @"Should return top-level packages");
  TAssertEqualObjects(spec.localFilePaths, @[],
                      @"Should have empty localFilePaths");
  TAssertEqualObjects(spec.postCommand, @"/usr/local/bin/gimp",
                      @"Should return postinstall command");
  TAssertTrue([spec isValid:&error], @"Spec should be valid");
  TAssertNil(error, @"Validation error should be nil");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testInstallSpecOSOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-override.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp", @"gimp-plugins"],
    @"postinstall_command": @"/usr/local/bin/gimp",
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp", @"gimp-plugin-registry"],
        @"postinstall_command": @"/usr/bin/gimp",
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse plist with overrides");
  // When no OS override path is injected, the spec uses current OS.
  // For testing, we'd need to inject the search order. Let's just verify
  // the parsing works and objects are created.
  TAssertNotNil(spec.packages, @"Should have packages");
  TAssert([spec.packages count] > 0, @"Should have at least one package");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testInstallSpecPartialOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-test-partial.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"postinstall_command": @"/usr/local/bin/gimp",
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp", @"gimp-plugin-registry"],
        // No postinstall_command override - should fall back
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeInstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse partial override plist");
  TAssertNotNil(spec.packages, @"Should have packages");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testUninstallSpecBasic
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-test-basic.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"postuninstall_command": @"/bin/echo Removed",
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeUninstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse uninstall plist");
  TAssertEqualObjects(spec.packages, (@[@"gimp"]),
                      @"Should have gimp package");
  TAssertEqualObjects(spec.postCommand, @"/bin/echo Removed",
                      @"Should have postuninstall command");
  TAssertTrue([spec isValid:&error], @"Spec should be valid");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testUninstallSpecOverride
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-test-override.plist"];

  NSDictionary *plist = @{
    @"packages": @[@"gimp"],
    @"os_overrides": @{
      @"debian": @{
        @"packages": @[@"gimp-extra"],
      },
    },
  };
  [plist writeToFile:plistPath atomically:YES];

  NSError *error = nil;
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                                        specType:GWPackageInstallSpecTypeUninstall
                                                                           error:&error];

  TAssertNotNil(spec, @"Should parse uninstall plist with override");
  TAssertNotNil(spec.packages, @"Should have packages");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

@end

#pragma mark - Backend Tests

@interface BackendTestHelper : NSObject
+ (BOOL)testDebBackendExecuteCommand;
+ (BOOL)testArchBackendExecuteCommand;
+ (BOOL)testFreeBSDBackendExecuteCommand;
+ (BOOL)testOpenBSDBackendExecuteCommand;
+ (BOOL)testInstallFailsReportsError;
+ (BOOL)testDebBackendIsPackageInstalledAgainstRealSystem;
+ (BOOL)testSudoCommandNeverDuplicatesToolPath;
@end

@implementation BackendTestHelper

+ (BOOL)testDebBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/apt-get"
                      arguments:@[@"install", @"-y", @"sl"]
                       exitCode:0
                         output:@"Installing sl..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/bin/apt-get"
                         arguments:@[@"install", @"-y", @"sl"]];
  TAssertTrue(exitCode == 0, @"apt-get install should succeed");
  TAssertTrue([executor.recordedCalls count] == 1,
              @"Should have recorded one call");

  NSDictionary *call = executor.recordedCalls[0];
  TAssertEqualObjects(call[@"path"], @"/usr/bin/apt-get",
                      @"Should record correct path");

  return YES;
}

+ (BOOL)testArchBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/pacman"
                      arguments:@[@"-S", @"--noconfirm", @"vim"]
                       exitCode:0
                         output:@"Installing vim..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/bin/pacman"
                         arguments:@[@"-S", @"--noconfirm", @"vim"]];
  TAssertTrue(exitCode == 0, @"pacman install should succeed");
  TAssertTrue([executor.recordedCalls count] == 1,
              @"Should have recorded one call");

  return YES;
}

+ (BOOL)testFreeBSDBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/sbin/pkg"
                      arguments:@[@"install", @"-y", @"tmux"]
                       exitCode:0
                         output:@"Installing tmux..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/sbin/pkg"
                         arguments:@[@"install", @"-y", @"tmux"]];
  TAssertTrue(exitCode == 0, @"pkg install should succeed");

  return YES;
}

+ (BOOL)testOpenBSDBackendExecuteCommand
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/sbin/pkg_add"
                      arguments:@[@"curl"]
                       exitCode:0
                         output:@"Installing curl..."
                   errorOutput:@""];

  int exitCode = [executor execute:@"/usr/sbin/pkg_add"
                         arguments:@[@"curl"]];
  TAssertTrue(exitCode == 0, @"pkg_add should succeed");

  return YES;
}

+ (BOOL)testInstallFailsReportsError
{
  GWMockSystemCommandExecutor *executor = [[GWMockSystemCommandExecutor alloc] init];
  [executor setResultForCommand:@"/usr/bin/apt-get"
                      arguments:@[@"install", @"-y", @"nonexistent-pkg"]
                       exitCode:100
                         output:@""
                   errorOutput:@"E: Unable to locate package nonexistent-pkg"];

  NSString *output = nil;
  int exitCode = [executor execute:@"/usr/bin/apt-get"
                         arguments:@[@"install", @"-y", @"nonexistent-pkg"]
                            output:&output];

  TAssertTrue(exitCode != 0, @"Should fail with non-zero exit code");
  TAssertNotNil(output, @"Should capture stdout");
  TAssertTrue([output length] == 0, @"Output should be empty on failure");

  return YES;
}

// A mocked executor only proves the backend parses whatever canned output
// the test author assumed dpkg-query would produce - it can't catch the
// backend invoking the wrong binary or an invalid flag, since the mock
// never actually runs anything. That gap let isPackageInstalled: call plain
// "dpkg -W" (dpkg has no -W; only dpkg-query does) ship silently: every
// query failed with a non-zero exit and was read as "not installed",
// so Software Update's prerequisites step tried to reinstall dozens of
// already-installed packages. Skips itself (returns YES) off Debian-family
// systems rather than asserting on the wrong package manager.
+ (BOOL)testDebBackendIsPackageInstalledAgainstRealSystem
{
  if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/dpkg-query"]) {
    return YES; // not a Debian-family system; nothing to verify here
  }

  GWDebBackend *backend = [[GWDebBackend alloc] init];

  TAssertTrue([backend isPackageInstalled:@"dpkg"],
              @"dpkg itself must be installed on any system that has dpkg-query");
  TAssertTrue(![backend isPackageInstalled:@"this-package-definitely-does-not-exist-xyz123"],
              @"a nonexistent package name must report not installed");

  return YES;
}

// Every backend built its argv the same hand-rolled way: prepend sudo's
// flags, then unconditionally re-add the tool's own path before the real
// arguments - correct when escalating through sudo (sudo's first argument
// names the program to run), but wrong when already root, where the launch
// path IS the tool and NSTask sets argv[0] to it on its own. The stray extra
// copy landed as the tool's first REAL argument: apt-get read
// "/usr/bin/apt-get" as an unknown operation and failed every real install
// this app ever ran as root (its actual production context), while every
// mocked backend test stayed green because tests run as a normal user, where
// the sudo-prefixed branch happens to mask the bug. Exercises whichever
// branch this process's real uid takes; CI usually runs as non-root, so a
// root run (as the privileged helper itself is) is the only way to see the
// other branch - see GWSudoHelper.h for why the invariant must hold either way.
+ (BOOL)testSudoCommandNeverDuplicatesToolPath
{
  NSString *toolPath = @"/usr/bin/apt-get";
  NSArray *toolArgs = @[@"install", @"-y", @"somepackage"];
  NSArray *args = nil;
  NSString *launchPath = GWSudoCommand(toolPath, toolArgs, &args);

  NSUInteger toolPathOccurrences = 0;
  for (NSString *arg in args) {
    if ([arg isEqualToString:toolPath]) toolPathOccurrences++;
  }

  if ([launchPath isEqualToString:toolPath]) {
    // Already root: NSTask supplies argv[0], so the tool path must not also
    // appear as a real argument.
    TAssertTrue(toolPathOccurrences == 0,
                @"already-root command must not repeat the tool path as an argument");
  } else {
    // Escalating: sudo needs the tool path as its own first argument, and
    // exactly once.
    TAssertTrue(toolPathOccurrences == 1,
                @"sudo command must name the tool path exactly once");
  }

  NSArray *trailingArgs = [args subarrayWithRange:NSMakeRange([args count] - [toolArgs count], [toolArgs count])];
  TAssertEqualObjects(trailingArgs, toolArgs,
                       @"the real arguments must survive, in order, as the command's tail");

  return YES;
}

@end

#pragma mark - GWPackageManager Public API Tests

@interface PackageManagerTestHelper : NSObject
+ (BOOL)testInitWithBackend;
+ (BOOL)testInstallPackagesNoProgress;
+ (BOOL)testInstallPackagesWithProgress;
+ (BOOL)testInstallPackagesFails;
+ (BOOL)testUninstallPackages;
+ (BOOL)testFilesForPackage;
+ (BOOL)testPackageOwningFile;
+ (BOOL)testIsPackageInstalled;
+ (BOOL)testMissingPackagesFrom;
+ (BOOL)testRunInstallFromPlistCallsBackend;
+ (BOOL)testRunInstallFromPlistInstallationFails;
+ (BOOL)testRunUninstallFromPlist;
+ (BOOL)testProgressForwarding;
@end

@implementation PackageManagerTestHelper

+ (BOOL)testInitWithBackend
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  TAssertNotNil(pm, @"PackageManager should be created");
  TAssertEqualObjects(pm.backend, mockBackend,
                      @"Should use the injected backend");

  return YES;
}

+ (BOOL)testInstallPackagesNoProgress
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"] error:&error];

  TAssertTrue(result, @"Install should succeed");
  TAssertNil(error, @"Error should be nil on success");
  TAssertTrue([mockBackend.recordedCalls count] == 1,
              @"Backend should be called once");
  NSDictionary *call = mockBackend.recordedCalls[0];
  TAssertEqualObjects(call[@"packages"], (@[@"sl"]),
                      @"Should pass package names to backend");

  return YES;
}

+ (BOOL)testInstallPackagesWithProgress
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];
  GWMockProgressHandler *progress = [[GWMockProgressHandler alloc] init];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"]
                     localFilePaths:nil
                          progress:progress
                             error:&error];

  TAssertTrue(result, @"Install should succeed");
  TAssertTrue([progress.progressCalls count] > 0,
              @"Progress handler should be called");

  // Verify progress stages
  NSDictionary *firstCall = progress.progressCalls[0];
  float firstProgress = [firstCall[@"progress"] floatValue];
  TAssertTrue(firstProgress == 0.0,
              @"First progress should be 0.0");

  return YES;
}

+ (BOOL)testInstallPackagesFails
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstallResult:NO error:nil];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm installPackages:@[@"sl"] error:&error];

  TAssertFalse(result, @"Install should fail");
  TAssertNotNil(error, @"Error should be set on failure");

  return YES;
}

+ (BOOL)testUninstallPackages
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm uninstallPackages:@[@"sl"] error:&error];

  TAssertTrue(result, @"Uninstall should succeed");
  TAssertNil(error, @"Error should be nil on success");
  TAssertTrue([mockBackend.recordedCalls count] == 1,
              @"Backend should be called once");
  NSDictionary *call = mockBackend.recordedCalls[0];
  TAssertEqualObjects(call[@"method"],
                      @"uninstallPackages:progress:error:",
                      @"Should call uninstall method");

  return YES;
}

+ (BOOL)testFilesForPackage
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setFilesResult:@[@"/usr/bin/sl", @"/usr/share/man/man6/sl.6.gz"]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  NSArray *files = [pm filesForPackage:@"sl" error:&error];

  TAssertNotNil(files, @"Should return files");
  TAssertTrue([files count] == 2,
              @"Should have 2 files for sl package");

  return YES;
}

+ (BOOL)testPackageOwningFile
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setOwningFileResult:@"sl"];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  NSString *owner = [pm packageOwningFile:@"/usr/games/sl" error:&error];

  TAssertEqualObjects(owner, @"sl",
                      @"Should identify sl as owning package");

  return YES;
}

+ (BOOL)testIsPackageInstalled
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstalledPackageNames:@[@"sl"]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  TAssertTrue([pm isPackageInstalled:@"sl"],
              @"sl was marked installed on the mock backend");
  TAssertTrue(![pm isPackageInstalled:@"freerdp"],
              @"freerdp was not marked installed on the mock backend");

  return YES;
}

+ (BOOL)testMissingPackagesFrom
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstalledPackageNames:@[@"sl"]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSArray *missing = [pm missingPackagesFrom:@[@"sl", @"freerdp", @"cowsay"]];

  TAssertEqualObjects(missing, (@[@"freerdp", @"cowsay"]),
                      @"Only the not-installed packages should come back, in order");

  return YES;
}

+ (BOOL)testRunInstallFromPlistCallsBackend
{
  // Create a temp install plist
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-plist-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    // Resolved via PATH by the /bin/sh -c wrapper; /bin/true does not
    // exist on all supported systems (e.g. NextBSD has only /usr/bin/true).
    @"postinstall_command": @"true",
    @"os_overrides": @{},
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runInstallFromPlistAtPath:plistPath
                                     progress:nil
                                        error:&error];

  TAssertTrue(result, @"Plist install should succeed");
  TAssertTrue([mockBackend.recordedCalls count] > 0,
              @"Backend should have been called");
  NSDictionary *call = [mockBackend.recordedCalls firstObject];
  TAssertEqualObjects(call[@"method"],
                      @"installPackages:localFilePaths:progress:error:",
                      @"Should call backend install method");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testRunInstallFromPlistInstallationFails
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"install-plist-fail-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    @"postinstall_command": @"/usr/games/sl",
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  [mockBackend setInstallResult:NO error:[NSError errorWithDomain:GWPackageManagerErrorDomain
                                                            code:GWPackageManagerErrorPackageNotFound
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Package not found"}]];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runInstallFromPlistAtPath:plistPath
                                     progress:nil
                                        error:&error];

  TAssertFalse(result, @"Plist install should fail when backend fails");
  TAssertNotNil(error, @"Error should be set");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testRunUninstallFromPlist
{
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *plistPath = [tmpDir stringByAppendingPathComponent:@"uninstall-plist-test.plist"];
  NSDictionary *plist = @{
    @"packages": @[@"sl"],
    @"postuninstall_command": @"/bin/echo Removed",
  };
  [plist writeToFile:plistPath atomically:YES];

  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];

  NSError *error = nil;
  BOOL result = [pm runUninstallFromPlistAtPath:plistPath
                                       progress:nil
                                          error:&error];

  TAssertTrue(result, @"Plist uninstall should succeed");
  TAssertTrue([mockBackend.recordedCalls count] > 0,
              @"Backend should have been called");

  [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
  return YES;
}

+ (BOOL)testProgressForwarding
{
  GWMockPackageManagerBackend *mockBackend = [[GWMockPackageManagerBackend alloc] init];
  GWPackageManager *pm = [[GWPackageManager alloc] initWithBackend:mockBackend];
  GWMockProgressHandler *progress = [[GWMockProgressHandler alloc] init];

  NSError *error = nil;
  [pm installPackages:@[@"sl"]
       localFilePaths:nil
            progress:progress
               error:&error];

  TAssertTrue([progress.progressCalls count] >= 2,
              @"Progress handler should receive multiple updates");

  NSDictionary *firstProgress = progress.progressCalls[0];
  TAssertTrue([firstProgress[@"progress"] floatValue] == 0.0,
              @"First progress update should be 0.0");

  return YES;
}

@end

#pragma mark - GWHeaderDatabase Tests

@interface GWHeaderDatabaseTestHelper : NSObject
+ (BOOL)testDatabaseOpens;
+ (BOOL)testPackageForGphoto2HeaderPerDistro;
+ (BOOL)testBestNameMatchPicksLibgphoto2;
+ (BOOL)testUnknownHeaderReturnsEmpty;
+ (BOOL)testDistroMappingForKnownFamilies;
@end

@implementation GWHeaderDatabaseTestHelper

// The database is checked into PackageManager/Resources/headers.db; the test
// binary runs from Tests/, so the file is one level up.
+ (GWHeaderDatabase *)testDatabase
{
  NSString *path = [@"../Resources/headers.db" stringByStandardizingPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path])
    path = @"../PackageManager/Resources/headers.db";
  NSError *error = nil;
  GWHeaderDatabase *db = [[GWHeaderDatabase alloc] initWithPath:path error:&error];
  return db;
}

+ (BOOL)testDatabaseOpens
{
  GWHeaderDatabase *db = [self testDatabase];
  TAssertNotNil(db, @"Database should open from Resources/headers.db");
  TAssertTrue([db isOpen], @"Database should report open");
  return YES;
}

+ (BOOL)testPackageForGphoto2HeaderPerDistro
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSArray *debian = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                        distro:@"debian"
                                         error:&error];
  TAssertNil(error, @"Debian lookup should not error");
  TAssertTrue([debian count] > 0, @"Debian should provide gphoto2/gphoto2.h");
  TAssertTrue([debian containsObject:@"libgphoto2-dev"],
              @"Debian provider should be libgphoto2-dev (got %@)", debian);

  NSArray *arch = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                       distro:@"arch"
                                        error:&error];
  TAssertTrue([arch count] > 0, @"Arch should provide gphoto2/gphoto2.h");
  TAssertTrue([arch containsObject:@"libgphoto2"],
              @"Arch provider should be libgphoto2 (got %@)", arch);

  NSArray *freebsd = [db packagesProvidingHeader:@"gphoto2/gphoto2.h"
                                          distro:@"freebsd"
                                           error:&error];
  TAssertTrue([freebsd count] > 0, @"FreeBSD should provide gphoto2/gphoto2.h");
  TAssertTrue([freebsd containsObject:@"libgphoto2"],
              @"FreeBSD provider should be libgphoto2 (got %@)", freebsd);

  return YES;
}

+ (BOOL)testBestNameMatchPicksLibgphoto2
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSString *debian = [db packageForHeader:@"gphoto2/gphoto2.h"
                                   distro:@"debian"
                                    error:&error];
  TAssertEqualObjects(debian, @"libgphoto2-dev",
                      @"Best name match on Debian should pick libgphoto2-dev (got %@)", debian);

  NSString *arch = [db packageForHeader:@"gphoto2/gphoto2.h"
                                 distro:@"arch"
                                  error:&error];
  TAssertEqualObjects(arch, @"libgphoto2",
                      @"Best name match on Arch should pick libgphoto2 (got %@)", arch);

  return YES;
}

+ (BOOL)testUnknownHeaderReturnsEmpty
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  NSError *error = nil;
  NSArray *packages = [db packagesProvidingHeader:@"no/such/header.h"
                                           distro:@"debian"
                                            error:&error];
  TAssertNil(error, @"Unknown header lookup should not error");
  TAssertTrue([packages count] == 0, @"Unknown header should have no providers");
  return YES;
}

+ (BOOL)testBareHeaderResolvesByBasename
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // "#include <gphoto2.h>" reaches the header via a -I subdirectory flag; it
  // must resolve to the same package as "gphoto2/gphoto2.h".
  NSError *error = nil;
  NSString *debian = [db packageForHeader:@"gphoto2.h" distro:@"debian" error:&error];
  TAssertNil(error, @"Bare gphoto2.h lookup should not error");
  TAssertEqualObjects(debian, @"libgphoto2-dev",
                      @"Bare gphoto2.h on Debian should resolve by basename (got %@)", debian);

  NSString *arch = [db packageForHeader:@"gphoto2.h" distro:@"arch" error:&error];
  TAssertEqualObjects(arch, @"libgphoto2",
                      @"Bare gphoto2.h on Arch should resolve by basename (got %@)", arch);

  NSString *freebsd = [db packageForHeader:@"gphoto2.h" distro:@"freebsd" error:&error];
  TAssertEqualObjects(freebsd, @"libgphoto2",
                      @"Bare gphoto2.h on FreeBSD should resolve by basename (got %@)", freebsd);

  return YES;
}

+ (BOOL)testAmbiguousBasenameStaysUnresolved
{
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // "config.h" is shipped by dozens of packages; it must not be resolved.
  NSError *error = nil;
  NSString *config = [db packageForHeader:@"config.h" distro:@"debian" error:&error];
  TAssertNil(error, @"Ambiguous basename lookup should not error");
  TAssertNil(config, @"Ambiguous basename config.h must stay unresolved (got %@)", config);

  return YES;
}

+ (BOOL)testDistroMappingForKnownFamilies
{
  // Deterministic regardless of host OS: map every family through the same
  // logic the database uses and verify only known distros come out.
  NSDictionary *expected = @{
    @"debian": @"debian", @"ubuntu": @"debian", @"devuan": @"debian",
    @"kali": @"debian", @"linuxmint": @"debian", @"raspbian": @"debian",
    @"pop": @"debian", @"elementary": @"debian", @"zorin": @"debian",
    @"arch": @"arch", @"manjaro": @"arch", @"endeavouros": @"arch",
    @"arcolinux": @"arch",
    @"freebsd": @"freebsd", @"ghostbsd": @"freebsd", @"dragonfly": @"freebsd",
  };
  GWHeaderDatabase *db = [self testDatabase];
  if (!db) return NO;

  // osSearchOrder for a synthetic os-release file lets us exercise the same
  // family mapping without changing the host's real /etc/os-release.
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *osReleasePath = [tmpDir stringByAppendingPathComponent:@"hdr-os-release-test"];
  for (NSString *osID in expected)
    {
      NSString *content = [NSString stringWithFormat:@"ID=%@\nID_LIKE=\n", osID];
      [content writeToFile:osReleasePath atomically:YES
                  encoding:NSUTF8StringEncoding error:nil];
      [GWOSDetector setOSReleasePathOverride:osReleasePath];

      NSString *family = [GWOSDetector packageManagerFamily];
      NSString *expectedDistro = expected[osID];
      NSString *mapped = nil;
      if ([family isEqualToString:@"debian"]) mapped = @"debian";
      else if ([family isEqualToString:@"arch"]) mapped = @"arch";
      else if ([family isEqualToString:@"freebsd"]) mapped = @"freebsd";

      TAssertEqualObjects(mapped, expectedDistro,
                          @"Family mapping for %@ should be %@", osID, expectedDistro);
    }

  // OpenBSD has no DB data.
  [GWOSDetector setUnameOverride:@"OpenBSD"];
  [GWOSDetector setOSReleasePathOverride:@"/nonexistent/os-release-test"];
  NSString *family = [GWOSDetector packageManagerFamily];
  TAssertEqualObjects(family, @"openbsd", @"OpenBSD family should be openbsd");

  [[NSFileManager defaultManager] removeItemAtPath:osReleasePath error:nil];
  [GWOSDetector setOSReleasePathOverride:nil];
  [GWOSDetector setUnameOverride:nil];
  return YES;
}

@end

#pragma mark - Test Runner

#pragma mark - Curl Meter / AppImage Download Tests

/* The half of GWAppImageDownloader that runs curl, driven here against a
 * local file so the test needs no network. The method is private to the
 * implementation; this declaration only lets the test name it. */
@interface GWAppImageDownloader (MeterTesting)
- (BOOL)_downloadURL:(NSString *)url
              toPath:(NSString *)dest
            progress:(id<GWInstallProgressHandler>)progress
               error:(NSError **)error;
@end

static BOOL testNearly(float a, float b)
{
  return (a > b - 0.0001f) && (a < b + 0.0001f);
}

@interface GWCurlMeterTestHelper : NSObject
@end

@implementation GWCurlMeterTestHelper

/* One meter update as curl writes it: a carriage return, that many bar
 * characters padded to the meter's 76 columns, then the percent. */
+ (NSString *)updateForPercent:(double)percent
{
  NSUInteger bars = (NSUInteger)(percent / 100.0 * 76.0);
  NSMutableString *bar = [NSMutableString string];
  for (NSUInteger i = 0; i < bars; i++)
    [bar appendString:@"#"];
  while ([bar length] < 76)
    [bar appendString:@" "];
  return [NSString stringWithFormat:@"\r%@%.1f%%", bar, percent];
}

+ (NSArray<NSNumber *> *)valuesOf:(GWMockProgressHandler *)mock
{
  NSMutableArray<NSNumber *> *values = [NSMutableArray array];
  for (NSDictionary *call in [mock progressCalls])
    [values addObject:call[@"progress"]];
  return values;
}

+ (BOOL)testMeterUpdatesBecomeFractions
{
  double percents[] = {0.0, 12.5, 42.0, 99.9, 100.0};
  size_t count = sizeof(percents) / sizeof(percents[0]);

  NSMutableString *stream = [NSMutableString string];
  for (size_t i = 0; i < count; i++)
    [stream appendString:[self updateForPercent:percents[i]]];
  [stream appendString:@"\n"];

  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];
  [reader ingestData:[stream dataUsingEncoding:NSUTF8StringEncoding]];
  [reader finish];

  NSArray<NSNumber *> *values = [self valuesOf:mock];
  TAssertTrue([values count] == (NSUInteger)count,
              @"Each whole percent of the meter should be reported once, got %lu",
              (unsigned long)[values count]);

  float previous = -1.0f;
  for (size_t i = 0; i < count; i++)
    {
      /* The transfer owns 0.05 .. 0.95 of the run, so 42 % of the bytes is
       * 0.428 of the install, not 42 % of the bar's width. */
      float expected = 0.05f + (0.95f - 0.05f) * (float)(percents[i] / 100.0);
      float value = [values[i] floatValue];
      TAssertTrue(testNearly(value, expected),
                  @"%.1f %% should map to %f, got %f",
                  percents[i], expected, value);
      TAssertTrue(value >= previous,
                  @"Progress should never move backwards (%f after %f)",
                  value, previous);
      previous = value;
    }

  TAssertEqualObjects([mock progressCalls][0][@"message"],
                      @"Downloading AppImage...",
                      @"The report should carry the phase text");
  return YES;
}

+ (BOOL)testMeterUpdatesSplitAcrossChunks
{
  /* curl writes whenever it feels like it, so an update is routinely cut in
   * half: three byte chunks split "42.0%" in the middle of the number. */
  NSMutableString *stream = [NSMutableString string];
  double percents[] = {0.0, 12.5, 42.0, 99.9, 100.0};
  size_t count = sizeof(percents) / sizeof(percents[0]);
  for (size_t i = 0; i < count; i++)
    [stream appendString:[self updateForPercent:percents[i]]];
  [stream appendString:@"\n"];

  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];

  NSData *data = [stream dataUsingEncoding:NSUTF8StringEncoding];
  const NSUInteger step = 3;
  for (NSUInteger offset = 0; offset < [data length]; offset += step)
    {
      NSUInteger length = MIN(step, [data length] - offset);
      [reader ingestData:[data subdataWithRange:NSMakeRange(offset, length)]];
    }
  [reader finish];

  NSArray<NSNumber *> *values = [self valuesOf:mock];
  TAssertTrue([values count] == (NSUInteger)count,
              @"A meter split across chunks should still yield every update, "
              @"got %lu", (unsigned long)[values count]);
  for (size_t i = 0; i < count; i++)
    {
      float expected = 0.05f + (0.95f - 0.05f) * (float)(percents[i] / 100.0);
      TAssertTrue(testNearly([values[i] floatValue], expected),
                  @"Update %lu mapped to %f instead of %f",
                  (unsigned long)i, [values[i] floatValue], expected);
    }
  return YES;
}

+ (BOOL)testSpinnerAndTextAreNotProgress
{
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];

  /* A transfer whose size the server never declared draws a spinner instead
   * of a percent: nothing is measurable, so nothing may be reported. */
  NSArray<NSString *> *noise = @[
    @"\r#=#=#                       ",
    @"\r##O#-#                   ",
    @"\rcurl: (22) The requested URL returned error: 404\n",
    @"\rTotal 42%\n",             /* a percent in prose is not a meter */
    @"a tail with no separator at all",
  ];
  for (NSString *text in noise)
    [reader ingestData:[text dataUsingEncoding:NSUTF8StringEncoding]];
  [reader ingestData:[NSData data]];
  [reader finish];

  TAssertTrue([mock.progressCalls count] == 0,
              @"Nothing measurable should report nothing, got %lu reports",
              (unsigned long)[mock.progressCalls count]);
  return YES;
}

+ (BOOL)testCurlTextLinesAreForwarded
{
  /* The stream is one thing to curl: the meter it draws, and the words it
   * writes when something goes wrong. Those words are the only place the
   * reason for a failure exists, so they have to come out the other end as
   * lines while the meter stays progress. */
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];

  NSMutableString *stream = [NSMutableString string];
  [stream appendString:[self updateForPercent:42.0]];
  [stream appendString:@"\r#=#=#                       "];
  [stream appendString:@"\rcurl: (22) The requested URL returned error: 403\n"];
  [stream appendString:[self updateForPercent:100.0]];
  [stream appendString:@"\n"];

  [reader ingestData:[stream dataUsingEncoding:NSUTF8StringEncoding]];
  [reader finish];

  TAssertTrue([[mock progressCalls] count] == 2,
              @"The two meter updates should still be the only reports, got %lu",
              (unsigned long)[[mock progressCalls] count]);
  TAssertTrue([[mock outputLines] count] == 1,
              @"The spinner is a picture and the meter is progress, so only "
              @"curl's own line should come through, got %lu",
              (unsigned long)[[mock outputLines] count]);
  TAssertEqualObjects([mock outputLines][0],
                      @"curl: (22) The requested URL returned error: 403",
                      @"The line should arrive as curl wrote it, got %s",
                      [[mock outputLines][0] UTF8String]);
  return YES;
}

+ (BOOL)testOutputLineSplitsTextFromMeterGlyphs
{
  /* The rule behind the forwarding: words come through, the meter's own
   * no-percent drawing does not, and whitespace is not part of the line. */
  TAssertNil([GWCurlMeterReader outputLineForSegment:@""],
             @"An empty segment has nothing to say");
  TAssertNil([GWCurlMeterReader outputLineForSegment:@"   \n"],
             @"A blank segment has nothing to say");
  TAssertNil([GWCurlMeterReader outputLineForSegment:@"#=#=#"],
             @"A spinner is a picture, not a line of text");
  TAssertNil([GWCurlMeterReader outputLineForSegment:@"  # #-=O#-  #"],
             @"A spinner with a glyph face in it is still a picture");
  TAssertEqualObjects(
      [GWCurlMeterReader outputLineForSegment:
          @"  curl: (6) Could not resolve host: github.com  "],
      @"curl: (6) Could not resolve host: github.com",
      @"Text should come through trimmed, got %s",
      [[GWCurlMeterReader outputLineForSegment:
          @"  curl: (6) Could not resolve host: github.com  "] UTF8String]);
  TAssertEqualObjects(
      [GWCurlMeterReader outputLineForSegment:@"Total 42%"],
      @"Total 42%",
      @"A percent in prose is text, not a meter update");
  return YES;
}

+ (BOOL)testStderrPipeLinesAreForwarded
{
  /* The release lookup has no meter to read, so its stderr goes through the
   * class entry point instead - including a line cut in half by a write. */
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  NSPipe *pipe = [NSPipe pipe];
  NSFileHandle *writer = [pipe fileHandleForWriting];
  [writer writeData:[@"curl: (22) The requested URL retur"
                     dataUsingEncoding:NSUTF8StringEncoding]];
  [writer writeData:[@"ned error: 403\n#=#=#\n"
                     dataUsingEncoding:NSUTF8StringEncoding]];
  [writer closeFile];

  [GWCurlMeterReader forwardStderrOfPipe:pipe toProgress:mock];

  TAssertTrue([[mock outputLines] count] == 1,
              @"A line split across writes should arrive once, and the "
              @"spinner after it not at all, got %lu: %s",
              (unsigned long)[[mock outputLines] count],
              [[[mock outputLines] componentsJoinedByString:@" | "] UTF8String]);
  TAssertEqualObjects([mock outputLines][0],
                      @"curl: (22) The requested URL returned error: 403",
                      @"The line should be reassembled, got %s",
                      [[mock outputLines][0] UTF8String]);
  TAssertTrue([[mock progressCalls] count] == 0,
              @"A silent curl has no meter to report, got %lu reports",
              (unsigned long)[[mock progressCalls] count]);
  return YES;
}

+ (BOOL)testWholePercentThrottle
{
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];

  /* The meter ticks faster than a bar moves: two updates in the same whole
   * percent are one report. A retry that restarts the transfer does move
   * the bar, so it is reported again. */
  for (NSString *percent in @[@"42.0", @"42.9", @"43.0", @"42.0"])
    [reader ingestData:[[NSString stringWithFormat:@"\r#### %@%%", percent]
                        dataUsingEncoding:NSUTF8StringEncoding]];
  [reader finish];

  NSArray<NSNumber *> *values = [self valuesOf:mock];
  TAssertTrue([values count] == 3,
              @"One report per whole percent, got %lu",
              (unsigned long)[values count]);
  TAssertTrue(testNearly([values[0] floatValue], 0.05f + 0.9f * 0.42f),
              @"First report at 42 %%, got %f", [values[0] floatValue]);
  TAssertTrue(testNearly([values[1] floatValue], 0.05f + 0.9f * 0.43f),
              @"43 %% should be reported, got %f", [values[1] floatValue]);
  TAssertTrue(testNearly([values[2] floatValue], 0.05f + 0.9f * 0.42f),
              @"A retry should move the bar back, got %f", [values[2] floatValue]);
  return YES;
}

+ (BOOL)testFinishReportsAnUnterminatedUpdate
{
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWCurlMeterReader *reader = [[GWCurlMeterReader alloc]
      initWithProgress:mock
               message:@"Downloading AppImage..."
                 first:0.05f
                   last:0.95f];

  [reader ingestData:[@"\r#### 77.0%" dataUsingEncoding:NSUTF8StringEncoding]];
  TAssertTrue([mock.progressCalls count] == 0,
              @"An update is only complete once its carriage return arrived");

  [reader finish];
  TAssertTrue([mock.progressCalls count] == 1,
              @"The last update of the stream should be reported, got %lu",
              (unsigned long)[mock.progressCalls count]);
  TAssertTrue(testNearly([mock.progressCalls[0][@"progress"] floatValue],
                         0.05f + 0.9f * 0.77f),
              @"77 %% should map to %f, got %f",
              0.05f + 0.9f * 0.77f,
              [mock.progressCalls[0][@"progress"] floatValue]);
  return YES;
}

+ (BOOL)testDownloadReportsCurlProgress
{
  NSString *source = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"gw_meter_%@.bin", [[NSUUID UUID] UUIDString]]];
  NSString *dest = [source stringByAppendingString:@".out"];
  NSMutableData *payload = [NSMutableData data];
  NSData *line = [@"0123456789abcdef" dataUsingEncoding:NSUTF8StringEncoding];
  while ([payload length] < 400000)
    [payload appendData:line];
  if (![payload writeToFile:source atomically:YES])
    {
      TAssertTrue(NO, @"The fixture file should be writable");
      return NO;
    }

  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWAppImageDownloader *downloader = [[GWAppImageDownloader alloc] init];
  NSError *error = nil;
  BOOL ok = [downloader _downloadURL:[@"file://" stringByAppendingString:source]
                              toPath:dest
                            progress:mock
                               error:&error];

  unsigned long long size = ok
      ? [[[NSFileManager defaultManager] attributesOfItemAtPath:dest
                                                        error:NULL] fileSize]
      : 0;
  NSArray<NSNumber *> *values = [self valuesOf:mock];
  BOOL ordered = YES;
  float previous = -1.0f;
  for (NSNumber *value in values)
    {
      if ([value floatValue] < previous)
        ordered = NO;
      previous = [value floatValue];
    }
  float last = ([values count] > 0) ? [values lastObject].floatValue : -1.0f;

  [[NSFileManager defaultManager] removeItemAtPath:source error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];

  TAssertTrue(ok, @"A file:// download should succeed (%@)",
              [error localizedDescription]);
  TAssertTrue(size == (unsigned long long)[payload length],
              @"The bytes on disk should match what curl was given");
  TAssertTrue([values count] >= 1,
              @"The run should start by saying nothing is measurable yet");
  TAssertTrue(testNearly([values[0] floatValue], -1.0f),
              @"The first report should be the indeterminate one, got %f",
              [values[0] floatValue]);
  TAssertTrue(ordered, @"Progress should never move backwards");
  if ([values count] > 1)
    {
      /* A transfer curl could measure must end where the download's slice of
       * the run ends - this is the number the button draws. */
      TAssertTrue(testNearly(last, 0.95f),
                  @"A finished transfer should end at 0.95, got %f", last);
      for (NSNumber *value in values)
        {
          if ([value floatValue] < 0.0f)
            continue;   /* the indeterminate report that opens the run */
          TAssertTrue([value floatValue] >= 0.0499f
                      && [value floatValue] <= 0.9501f,
                      @"Every byte report belongs to the download's slice, got %f",
                      [value floatValue]);
        }
    }
  return YES;
}

+ (BOOL)testDownloadForwardsCurlFailure
{
  /* End to end: the download's own failure text, which is the evidence the
   * caller rewrites its error from, has to arrive at the handler. */
  NSString *missing = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"gw_absent_%@.AppImage",
        [[NSUUID UUID] UUIDString]]];
  GWMockProgressHandler *mock = [[GWMockProgressHandler alloc] init];
  GWAppImageDownloader *downloader = [[GWAppImageDownloader alloc] init];
  NSError *error = nil;
  BOOL ok = [downloader _downloadURL:[@"file://" stringByAppendingString:missing]
                              toPath:[missing stringByAppendingString:@".out"]
                            progress:mock
                               error:&error];

  NSArray<NSString *> *lines = [mock outputLines];
  TAssertFalse(ok, @"A file:// URL that is not there should fail the download");
  TAssertNotNil(error, @"The failure should be reported as an error");
  TAssertTrue([lines count] >= 1,
              @"curl's own reason for failing should reach the handler, got %lu",
              (unsigned long)[lines count]);
  if ([lines count] > 0)
    TAssertTrue([lines[0] hasPrefix:@"curl:"],
                @"The handler should see curl's line verbatim, got \"%s\"",
                [lines[0] UTF8String]);
  return YES;
}

@end

@interface TestRunner : NSObject
+ (int)runAllTests;
@end

@implementation TestRunner

+ (int)runAllTests
{
  // --- GWOSDetector Tests ---
  runTest(@"testFreeBSDWithOSRelease", ^{
    return [GWOSDetectorTestHelper testFreeBSDWithOSRelease];
  });
  runTest(@"testFreeBSDWithoutOSReleaseFallbackToUname", ^{
    return [GWOSDetectorTestHelper testFreeBSDWithoutOSReleaseFallbackToUname];
  });
  runTest(@"testLinuxWithOSRelease", ^{
    return [GWOSDetectorTestHelper testLinuxWithOSRelease];
  });
  runTest(@"testDependencySearchOrderPerDistribution", ^{
    return [GWOSDetectorTestHelper testDependencySearchOrderPerDistribution];
  });
  runTest(@"testDependencySearchOrderFamilyBeforeKernel", ^{
    return [GWOSDetectorTestHelper testDependencySearchOrderFamilyBeforeKernel];
  });
  runTest(@"testInstallSpecPicksDistributionPackages", ^{
    return [GWOSDetectorTestHelper testInstallSpecPicksDistributionPackages];
  });
  runTest(@"testInstallSpecFallsBackToKernelEntry", ^{
    return [GWOSDetectorTestHelper testInstallSpecFallsBackToKernelEntry];
  });
  runTest(@"testLinuxMultipleIDLike", ^{
    return [GWOSDetectorTestHelper testLinuxMultipleIDLike];
  });
  runTest(@"testOpenBSDWithoutOSRelease", ^{
    return [GWOSDetectorTestHelper testOpenBSDWithoutOSRelease];
  });

  // --- GWPackageInstallSpec Tests ---
  runTest(@"testInstallSpecNoOverrides", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecNoOverrides];
  });
  runTest(@"testInstallSpecOSOverride", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecOSOverride];
  });
  runTest(@"testInstallSpecPartialOverride", ^{
    return [GWPackageInstallSpecTestHelper testInstallSpecPartialOverride];
  });
  runTest(@"testUninstallSpecBasic", ^{
    return [GWPackageInstallSpecTestHelper testUninstallSpecBasic];
  });
  runTest(@"testUninstallSpecOverride", ^{
    return [GWPackageInstallSpecTestHelper testUninstallSpecOverride];
  });

  // --- Backend Tests ---
  runTest(@"testDebBackendExecuteCommand", ^{
    return [BackendTestHelper testDebBackendExecuteCommand];
  });
  runTest(@"testArchBackendExecuteCommand", ^{
    return [BackendTestHelper testArchBackendExecuteCommand];
  });
  runTest(@"testFreeBSDBackendExecuteCommand", ^{
    return [BackendTestHelper testFreeBSDBackendExecuteCommand];
  });
  runTest(@"testOpenBSDBackendExecuteCommand", ^{
    return [BackendTestHelper testOpenBSDBackendExecuteCommand];
  });
  runTest(@"testInstallFailsReportsError", ^{
    return [BackendTestHelper testInstallFailsReportsError];
  });
  runTest(@"testDebBackendIsPackageInstalledAgainstRealSystem", ^{
    return [BackendTestHelper testDebBackendIsPackageInstalledAgainstRealSystem];
  });
  runTest(@"testSudoCommandNeverDuplicatesToolPath", ^{
    return [BackendTestHelper testSudoCommandNeverDuplicatesToolPath];
  });

  // --- GWPackageManager API Tests ---
  runTest(@"testInitWithBackend", ^{
    return [PackageManagerTestHelper testInitWithBackend];
  });
  runTest(@"testInstallPackagesNoProgress", ^{
    return [PackageManagerTestHelper testInstallPackagesNoProgress];
  });
  runTest(@"testInstallPackagesWithProgress", ^{
    return [PackageManagerTestHelper testInstallPackagesWithProgress];
  });
  runTest(@"testInstallPackagesFails", ^{
    return [PackageManagerTestHelper testInstallPackagesFails];
  });
  runTest(@"testUninstallPackages", ^{
    return [PackageManagerTestHelper testUninstallPackages];
  });
  runTest(@"testFilesForPackage", ^{
    return [PackageManagerTestHelper testFilesForPackage];
  });
  runTest(@"testPackageOwningFile", ^{
    return [PackageManagerTestHelper testPackageOwningFile];
  });
  runTest(@"testIsPackageInstalled", ^{
    return [PackageManagerTestHelper testIsPackageInstalled];
  });
  runTest(@"testMissingPackagesFrom", ^{
    return [PackageManagerTestHelper testMissingPackagesFrom];
  });
  runTest(@"testRunInstallFromPlistCallsBackend", ^{
    return [PackageManagerTestHelper testRunInstallFromPlistCallsBackend];
  });
  runTest(@"testRunInstallFromPlistInstallationFails", ^{
    return [PackageManagerTestHelper testRunInstallFromPlistInstallationFails];
  });
  runTest(@"testRunUninstallFromPlist", ^{
    return [PackageManagerTestHelper testRunUninstallFromPlist];
  });
  runTest(@"testProgressForwarding", ^{
    return [PackageManagerTestHelper testProgressForwarding];
  });

  // --- GWHeaderDatabase Tests ---
  runTest(@"testDatabaseOpens", ^{
    return [GWHeaderDatabaseTestHelper testDatabaseOpens];
  });
  runTest(@"testPackageForGphoto2HeaderPerDistro", ^{
    return [GWHeaderDatabaseTestHelper testPackageForGphoto2HeaderPerDistro];
  });
  runTest(@"testBestNameMatchPicksLibgphoto2", ^{
    return [GWHeaderDatabaseTestHelper testBestNameMatchPicksLibgphoto2];
  });
  runTest(@"testUnknownHeaderReturnsEmpty", ^{
    return [GWHeaderDatabaseTestHelper testUnknownHeaderReturnsEmpty];
  });
  runTest(@"testBareHeaderResolvesByBasename", ^{
    return [GWHeaderDatabaseTestHelper testBareHeaderResolvesByBasename];
  });
  runTest(@"testAmbiguousBasenameStaysUnresolved", ^{
    return [GWHeaderDatabaseTestHelper testAmbiguousBasenameStaysUnresolved];
  });
  runTest(@"testDistroMappingForKnownFamilies", ^{
    return [GWHeaderDatabaseTestHelper testDistroMappingForKnownFamilies];
  });

  // --- AppImage download progress (curl's meter) ---
  runTest(@"testMeterUpdatesBecomeFractions", ^{
    return [GWCurlMeterTestHelper testMeterUpdatesBecomeFractions];
  });
  runTest(@"testMeterUpdatesSplitAcrossChunks", ^{
    return [GWCurlMeterTestHelper testMeterUpdatesSplitAcrossChunks];
  });
  runTest(@"testSpinnerAndTextAreNotProgress", ^{
    return [GWCurlMeterTestHelper testSpinnerAndTextAreNotProgress];
  });
  runTest(@"testCurlTextLinesAreForwarded", ^{
    return [GWCurlMeterTestHelper testCurlTextLinesAreForwarded];
  });
  runTest(@"testOutputLineSplitsTextFromMeterGlyphs", ^{
    return [GWCurlMeterTestHelper testOutputLineSplitsTextFromMeterGlyphs];
  });
  runTest(@"testStderrPipeLinesAreForwarded", ^{
    return [GWCurlMeterTestHelper testStderrPipeLinesAreForwarded];
  });
  runTest(@"testWholePercentThrottle", ^{
    return [GWCurlMeterTestHelper testWholePercentThrottle];
  });
  runTest(@"testFinishReportsAnUnterminatedUpdate", ^{
    return [GWCurlMeterTestHelper testFinishReportsAnUnterminatedUpdate];
  });
  runTest(@"testDownloadReportsCurlProgress", ^{
    return [GWCurlMeterTestHelper testDownloadReportsCurlProgress];
  });
  runTest(@"testDownloadForwardsCurlFailure", ^{
    return [GWCurlMeterTestHelper testDownloadForwardsCurlFailure];
  });

  // --- AppImage asset picking (real releases, see the file's header) ---
  AGRegisterAppImageAssetPickerTests();

  // --- AppImage picking from a download.kde.org directory (real pages) ---
  AGRegisterKDEAppImagePickerTests();

  return (failCount == 0) ? 0 : 1;
}

@end

int main(int argc, const char *argv[])
{
  @autoreleasepool
    {
      NSLog(@"========================================");
      NSLog(@"  GWPackageManager Test Suite");
      NSLog(@"========================================\n");

      int result = [TestRunner runAllTests];

      NSLog(@"\n========================================");
      NSLog(@"  Results: %d passed, %d failed out of %d",
            passCount, failCount, testCount);
      NSLog(@"========================================");

      return result;
    }
}
