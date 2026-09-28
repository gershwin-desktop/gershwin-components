/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageDownloader - Downloads an AppImage (a direct URL, or the newest
 * GitHub release that actually ships one for this machine) and places it
 * directly into ~/Applications as a flat, executable <name>.AppImage file
 * (no .app wrapper).
 */

#import <Foundation/Foundation.h>

@protocol GWInstallProgressHandler;

@interface GWAppImageDownloader : NSObject

// Downloads an already-known AppImage URL into ~/Applications/<appName>.AppImage
- (BOOL)downloadAppImageFromURL:(NSString *)url
                         appName:(NSString *)appName
                        progress:(nullable id<GWInstallProgressHandler>)progress
                           error:(NSError **)error;

// Resolves the AppImage for the current architecture from <repo> ("owner/repo")
// and downloads it. "The release" is the newest one that actually ships an
// AppImage, preferring the newest that is not a pre-release, and "the
// AppImage" is the one file in it that GWAppImageAssetPicker picks.
//
// appName is the catalog's name for the application, not the repository's:
// one release can hold AppImages of several programs, and this is what tells
// them apart. Pass nil when there is only one candidate.
- (BOOL)downloadAppImageFromGitHubRepo:(NSString *)repo
                                appName:(NSString *)appName
                               progress:(nullable id<GWInstallProgressHandler>)progress
                                  error:(NSError **)error;

// Resolves the AppImage for the current architecture from a download.kde.org
// application directory and downloads it. A KDE link names a directory rather
// than a file (https://download.kde.org/stable/digikam/), so this reads the
// directory index, takes the newest version directory that holds an AppImage,
// and asks GWKDEAppImagePicker which file in it is this machine's build.
//
// The architecture is a requirement here, not a preference: every AppImage
// download.kde.org ships is x86-64, so there is nothing to fall back to for
// an aarch64 machine, and a failure is reported instead of downloading a file
// that cannot run.
//
// appName is the catalog's name for the application, as above.
- (BOOL)downloadAppImageFromKDEListingURL:(NSString *)listingURL
                                 appName:(NSString *)appName
                                progress:(nullable id<GWInstallProgressHandler>)progress
                                   error:(NSError **)error;

// Path of the downloaded AppImage for appName.  Used to launch the app after
// download and to detect an already-downloaded AppImage.
+ (NSString *)launcherPathForAppName:(NSString *)appName;

// Where launcherPathForAppName: puts new downloads (~/Applications), and the
// directory they went to before the download folder moved there
// (~/Library/Applications), which existingLauncherPathForAppName: still
// checks for an install made before the move.
+ (NSString *)applicationsDirectory;
+ (NSString *)legacyApplicationsDirectory;

// The launcher path an install can actually be found at: the current
// directory while the file is there, the pre-move directory if that is where
// it still is, and the current path as the download target when there is no
// file yet.
+ (NSString *)existingLauncherPathForAppName:(NSString *)appName;

@end
