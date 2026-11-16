/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWPrerequisitesInstaller - spec screen 4: installs missing OS packages
 * from gershwin-developer's Library/OSSupport/<os-id>.txt. Reuses
 * GWPackageManager/GWOSDetector from PackageManager instead of new per-OS
 * shell code; this class only locates the right package list and turns it
 * into "which are missing" / "install them" calls.
 */

#import <Foundation/Foundation.h>
#import <PackageManager/GWPackageManager.h>
#import <PackageManager/GWOSDetector.h>
#import "SWGitTool.h" // SWGitLogLine

@interface SWPrerequisitesInstaller : NSObject

// packageManager == nil uses GWPackageManager.sharedManager; osIdentifier ==
// nil uses GWOSDetector.currentOSIdentifier (both injectable for testing).
- (instancetype)initWithOSSupportDirectory:(NSString *)osSupportDirectory
                            packageManager:(GWPackageManager *)packageManager
                             osIdentifier:(NSString *)osIdentifier;

// Optional. When set, every line the underlying package manager tool prints
// (apt-get's/pacman's/pkg's real stdout+stderr) is forwarded here as it runs,
// the same way SWGitTool/SWRepositoryUpdater stream their commands - without
// this, the whole prerequisites phase runs silently and a stuck command
// (e.g. a debconf prompt with no tty attached) looks like a plain hang.
@property (nonatomic, copy) SWGitLogLine logHandler;

// The OS whose package list is used, e.g. "nextbsd"; nil when undetectable.
@property (nonatomic, readonly, copy) NSString *osIdentifier;

// Optional. The contents of this OS's package list in a gershwin-developer
// version that has been fetched but is not being applied in this run. A
// repository updated now may already need what that list adds, and the
// lists only ever grow with what newer code needs, so the union of both is
// installed: an extra package is harmless, a missing one breaks the build.
@property (nonatomic, copy) NSString *incomingPackageList;

// The packages named for this OS in Library/OSSupport/<os-id>.txt (OS
// variants alias onto their family's file via a symlink there, e.g.
// artix.txt -> arch.txt), followed by those -incomingPackageList adds, or
// nil if neither names a list for this OS.
- (NSArray<NSString *> *)declaredPackages;

// The subset of -declaredPackages that is not currently installed, in the
// order -declaredPackages lists them. Empty (never nil) when nothing is
// missing or nothing is declared for this OS.
- (NSArray<NSString *> *)missingPackages;

// Installs whichever of -declaredPackages are not already installed. If
// nothing is missing, succeeds immediately without touching the package
// manager. progress is called once per package as it starts installing
// ("Installing freerdp (package 2 of 3)"); on failure, error names the
// package that failed. Fails when there is no package list for this OS at
// all: passing then would build without knowing what the build needs.
- (BOOL)installMissingPackagesWithProgress:(void (^)(NSString *packageName, NSUInteger index, NSUInteger total))progress
                                       error:(NSError **)error;

@end
