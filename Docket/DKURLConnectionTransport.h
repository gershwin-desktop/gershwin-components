/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "DKGistTransport.h"

/* The real transport used outside tests: a thin wrapper around
 * NSURLConnection's synchronous API, matching the pattern already used
 * elsewhere in this codebase for GitHub API calls (e.g. CLMGitHubAPI). */
@interface DKURLConnectionTransport : NSObject <DKGistTransport>
@end
