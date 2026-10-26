/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PodcastChapter_h
#define PodcastChapter_h

#import <Foundation/Foundation.h>

/**
 * PodcastChapter
 *
 * One chapter mark of an episode: a title and the time, in seconds from
 * the start, it begins at. Read either from Podlove Simple Chapters
 * (<psc:chapters> inline in the feed item) or from the Podcast Namespace's
 * external chapters JSON (<podcast:chapters url="...">).
 */
@interface PodcastChapter : NSObject

@property (nonatomic, retain) NSString *title;
@property (nonatomic, assign) NSTimeInterval startTime;

- (instancetype)initWithTitle:(NSString *)title startTime:(NSTimeInterval)startTime;

/// Parses a Podlove Simple Chapters start attribute: "HH:MM:SS.mmm",
/// "MM:SS.mmm" or plain seconds. Returns 0 for text it cannot parse.
+ (NSTimeInterval)secondsFromPSCTimeString:(NSString *)string;

/// Downloads and parses a Podcast Namespace chapters JSON file
/// ({"chapters":[{"startTime":N,"title":"..."}, ...]}); completion runs on
/// the main thread. chapters is nil on error.
+ (void)fetchChaptersFromURL:(NSString *)url
                   completion:(void(^)(NSArray *chapters, NSError *error))completion;

@end

#endif /* PodcastChapter_h */
