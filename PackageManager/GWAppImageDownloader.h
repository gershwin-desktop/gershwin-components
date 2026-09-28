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

// Downloads an already-known AppImage URL into ~/Library/Applications/<appName>.app
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

// Path of the launcher inside the downloaded .app bundle.  Used to launch the
// app after download and to detect an already-downloaded AppImage.
+ (NSString *)launcherPathForAppName:(NSString *)appName;

@end
