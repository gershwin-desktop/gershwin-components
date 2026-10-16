/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PodcastFeedParser_h
#define PodcastFeedParser_h

#import <Foundation/Foundation.h>

/**
 * PodcastFeedParser
 *
 * Downloads a podcast's RSS feed and parses its <item> entries into
 * PodcastEpisode objects. Does not download episode audio - streaming
 * only, per Player's podcast feature.
 */
@interface PodcastFeedParser : NSObject <NSXMLParserDelegate>

/// Download and parse feedURL; completion runs on the main thread.
+ (void)fetchEpisodesForFeedURL:(NSString *)feedURL
                      completion:(void(^)(NSArray *episodes, NSError *error))completion;

@end

#endif /* PodcastFeedParser_h */
