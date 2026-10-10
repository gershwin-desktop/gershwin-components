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

// The packages named for this OS in Library/OSSupport/<os-id>.txt (OS
// variants alias onto their family's file via a symlink there, e.g.
// artix.txt -> arch.txt), or nil if no list exists for this OS at all -
// callers should treat that as "no prerequisites known", not as an error.
- (NSArray<NSString *> *)declaredPackages;

// The subset of -declaredPackages that is not currently installed, in the
// order -declaredPackages lists them. Empty (never nil) when nothing is
// missing or nothing is declared for this OS.
- (NSArray<NSString *> *)missingPackages;

// Installs whichever of -declaredPackages are not already installed. If
// nothing is missing, succeeds immediately without touching the package
// manager. progress is called once per package as it starts installing
// ("Installing freerdp (package 2 of 3)"); on failure, error names the
// package that failed.
- (BOOL)installMissingPackagesWithProgress:(void (^)(NSString *packageName, NSUInteger index, NSUInteger total))progress
                                       error:(NSError **)error;

@end
