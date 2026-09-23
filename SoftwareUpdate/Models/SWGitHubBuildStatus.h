/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWGitHubBuildStatus - GitHub check-runs status for the tip of a branch,
 * cached per commit sha (unauthenticated API calls are rate-limited, so the
 * same sha is never queried twice in one run).
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"

// Fetches the raw response body for a GitHub API URL, or nil on failure.
// Injected so tests never hit the real network.
typedef NSData * (^SWHTTPFetcher)(NSURL *url);

@interface SWGitHubBuildStatus : NSObject

// fetcher == nil uses a real synchronous NSURLConnection fetch.
- (instancetype)initWithFetcher:(SWHTTPFetcher)fetcher;

// repoName is the bare name under github.com/gershwin-desktop/, e.g.
// "gershwin-workspace". Result is cached per sha; a second call for the
// same sha never repeats the network request.
- (SWBuildStatus)statusForRepositoryNamed:(NSString *)repoName sha:(NSString *)sha;

- (void)clearCache;

@end
