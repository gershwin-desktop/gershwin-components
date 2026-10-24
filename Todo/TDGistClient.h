/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "TDGistTransport.h"

extern NSString * const TDGistClientErrorDomain;

/*
 * Talks to exactly one GitHub gist through the REST API (one gist holds
 * every Todo list, one file per list). The personal access token is
 * supplied by the caller; TDGistClient does not know or care where it
 * came from (see TDPreferences for where it is read from today).
 */
@interface TDGistClient : NSObject
{
  NSString *_gistId;
  NSString *_token;
  id <TDGistTransport> _transport;
}

- (instancetype)initWithGistId: (NSString *)gistId
                          token: (NSString *)token
                      transport: (id <TDGistTransport>)transport;

/*
 * Fetches the gist. On success, returns a dictionary with:
 *   "files"      - NSDictionary of filename (NSString) -> content (NSString)
 *   "updated_at" - NSString, the gist's last-modified timestamp as GitHub
 *                  reports it; TDStore compares this against the value
 *                  saved at the last pull to detect a remote change.
 * Returns nil and sets *error on any failure (network, non-200, bad JSON).
 */
- (NSDictionary *)fetchGistWithError: (NSError **)error;

/*
 * Replaces the content of exactly the given files in the gist (a
 * filename -> content NSString mapping); files not mentioned are left
 * untouched by the GitHub API. Returns NO and sets *error on failure.
 */
- (BOOL)updateGistFiles: (NSDictionary *)filenameToContent
                   error: (NSError **)error;

@end
