/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageManagerBackend - Protocol for package manager backends.
 * Each OS platform provides its own backend implementation.
 */

#import <Foundation/Foundation.h>

@protocol GWInstallProgressHandler;

@protocol GWPackageManagerBackend <NSObject>

@property (readonly) NSString *backendName;

@required

// Whether packageName is currently installed, checked the native way for
// this platform (dpkg-query/pacman -Qi/pkg info -e/pkg_info -e). Used to
// find which of a prerequisite list are missing before installing them.
- (BOOL)isPackageInstalled:(NSString *)packageName;

// Install/uninstall with progress support
- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
             progress:(nullable id<GWInstallProgressHandler>)progressHandler
                error:(NSError **)error;

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                progress:(nullable id<GWInstallProgressHandler>)progressHandler
                   error:(NSError **)error;

// File/package queries
- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error;
- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error;

@optional
/// Full stderr output from the most recent backend command, suitable for
/// display in a "Details" disclosure area.  Set during installPackages:
/// and uninstallPackages:; valid after those methods return.
@property (readonly) NSString *capturedErrorOutput;

@end
