/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGApp;

typedef NS_ENUM(NSInteger, AGDownloadKind) {
    AGDownloadKindGitHubLatestRelease, // payload: githubRepo
    AGDownloadKindDirectURL,           // payload: URL of an .AppImage file
    AGDownloadKindWebPageOnly,         // payload: downloadPageURL; we cannot fetch a file
    AGDownloadKindNone                 // no links at all
};

// Decides how an application can be obtained. Pure logic: no network, no
// disk, no PackageManager, so the decision can be tested on its own.
//
// This never looks at a release, so it never learns a tag and never chooses
// a file: those rules belong to PackageManager's downloader and asset picker
// (section 8 of the brief). GitHubLatestRelease is a promise to ask it, and
// the name is historical - "latest" now means the newest release that
// actually ships an AppImage.
@interface AGDownloadResolver : NSObject

// The architecture this machine reports, read from the kernel. A caller that
// wants to decide for another machine passes its own string below.
+ (NSString *)currentArchitecture;

+ (AGDownloadKind)kindForApp:(AGApp *)app payload:(id *)payload;

// *payload receives whatever the chosen kind needs (see the enum comments)
// and is set to nil first, so a caller that keeps a stale pointer never
// reads the previous app's value. Either argument may be NULL.
+ (AGDownloadKind)kindForApp:(AGApp *)app
               architecture:(NSString *)architecture
                    payload:(id *)payload;

@end
