/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PodcastSearch_h
#define PodcastSearch_h

#import <Foundation/Foundation.h>

/**
 * PodcastSearch
 *
 * Client for Apple's iTunes Search API, restricted to podcasts:
 * https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html
 */
@interface PodcastSearch : NSObject

/// Shared singleton instance
+ (instancetype)sharedSearch;

/// Search podcasts by title/publisher/keyword
- (void)searchPodcasts:(NSString *)query
             completion:(void(^)(NSArray *podcasts, NSError *error))completion;

@end

#endif /* PodcastSearch_h */
