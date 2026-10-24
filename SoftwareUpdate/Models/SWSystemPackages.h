/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWSystemPackages - the operating system's own packages as one more item in
 * Software Update's list. On NextBSD the base system (kernel, userland, ...)
 * ships as pkg packages from a repository named "NextBSD"; when that
 * repository has newer versions of installed packages, the list offers a
 * "NextBSD" item, and the update run upgrades them before any git work.
 *
 * The check runs as the user, and pkg's own catalogue is no help there:
 * "pkg update" needs root and pkg refuses a user-owned database. So the
 * checker reads the repository URL from "pkg -vv", downloads that
 * repository's packagesite.pkg itself, and compares its manifest with
 * "pkg query" using "pkg version -t". Everything that runs a command takes
 * it from an injected block, so all of it is testable without pkg.
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"

// The pkg repository whose packages make up the base system, and the name
// the list item carries.
extern NSString *const SWNextBSDRepositoryName;
// The progress window's phase for it, and the helper's PHASE: event.
extern NSString *const SWSystemPackagesPhaseIdentifier;

@interface SWSystemPackageUpgrade : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *installedVersion;
@property (nonatomic, copy) NSString *availableVersion;
// The kernel cannot be replaced under a running system.
@property (nonatomic, readonly) BOOL isKernel;
// "name installed -> available", for the details pane.
- (NSString *)displayLine;
@end

// NSOrderedAscending when installed is older than available.
typedef NSComparisonResult (^SWVersionComparator)(NSString *installed, NSString *available);

// Runs a command to completion and returns its standard output (standard
// error is dropped: pkg prints unrelated ABI warnings there), or nil when it
// could not be started. outStatus receives the exit status.
typedef NSString *(^SWCommandOutputRunner)(NSString *launchPath, NSArray<NSString *> *arguments,
                                           int *outStatus);

// Runs a command with extra environment, handing every output line (stdout
// and stderr) to lineHandler as it arrives; returns the exit status.
typedef int (^SWStreamingCommandRunner)(NSString *launchPath, NSArray<NSString *> *arguments,
                                        NSDictionary<NSString *, NSString *> *environment,
                                        void (^lineHandler)(NSString *line));

// The runner the checker uses when given none: runs the real command.
SWCommandOutputRunner SWDefaultCommandOutputRunner(void);

@interface SWSystemPackages : NSObject

// The url of the repository called name in the "Repositories:" section of
// "pkg -vv", with a "pkg+" (SRV mirror) prefix removed; nil if not found.
+ (NSString *)repositoryURLFromPkgConfiguration:(NSString *)pkgVerboseOutput
                                 repositoryName:(NSString *)name;

// name -> version for every package in a packagesite.yaml (one JSON object
// per line); lines that are not such an object are skipped.
+ (NSDictionary<NSString *, NSString *> *)packageVersionsFromManifest:(NSString *)manifest;

// name -> version from "pkg query '%R %n %v'", only for packages that came
// from the repository called name.
+ (NSDictionary<NSString *, NSString *> *)installedPackagesFromQueryOutput:(NSString *)output
                                                            repositoryName:(NSString *)name;

// Installed packages for which available has a newer version, by name.
+ (NSArray<SWSystemPackageUpgrade *> *)pendingUpgradesForInstalled:(NSDictionary<NSString *, NSString *> *)installed
                                                          available:(NSDictionary<NSString *, NSString *> *)available
                                                         comparator:(SWVersionComparator)comparator;

+ (BOOL)upgradesRequireRestart:(NSArray<SWSystemPackageUpgrade *> *)upgrades;

@end

@interface SWSystemPackageChecker : NSObject

// runner nil runs the real commands.
- (instancetype)initWithRepositoryName:(NSString *)repositoryName
                         commandRunner:(SWCommandOutputRunner)runner
                            logHandler:(void (^)(NSString *line))logHandler;

// The pending upgrades (possibly none), or nil when they could not be
// determined; the reason has then been logged. A failure here must never
// stand in the way of the git updates, so callers simply show no item.
- (NSArray<SWSystemPackageUpgrade *> *)pendingUpgrades;

@end

@interface SWSystemPackageUpgrader : NSObject

// Runs as root, in the privileged helper. runner is required: the helper
// passes one that also feeds the Log window.
- (instancetype)initWithCommandRunner:(SWStreamingCommandRunner)runner
                           logHandler:(void (^)(NSString *line))logHandler;

// How often a "database is locked" pkg run is tried, and the pause between.
@property (nonatomic) NSUInteger maxLockAttempts;
@property (nonatomic) NSTimeInterval lockRetryDelay;

// "pkg update", then "pkg upgrade -y", both limited to the NextBSD
// repository. NO with outError set on failure.
- (BOOL)upgradeWithStepHandler:(void (^)(NSString *stepVerb))stepHandler
                         error:(NSString **)outError;

@end

@interface SWRepository (SWSystemPackages)
// The synthetic list item for the base system: selected, and needing a
// restart when a kernel package is among the upgrades.
+ (instancetype)systemPackagesItemNamed:(NSString *)name
                               upgrades:(NSArray<SWSystemPackageUpgrade *> *)upgrades;
@end
