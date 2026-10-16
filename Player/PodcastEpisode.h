/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PodcastEpisode_h
#define PodcastEpisode_h

#import <Foundation/Foundation.h>

/**
 * PodcastEpisode
 *
 * One entry (<item>) of a podcast's RSS/Atom feed. Episodes are not
 * persisted - the feed is re-read each time a show's episode list is
 * opened.
 */
@interface PodcastEpisode : NSObject
{
@private
    NSString *_title;
    NSString *_pubDateString;
    NSDate *_pubDate;
    NSString *_durationString;
    NSString *_summary;
    NSString *_streamURL;
    NSString *_mimeType;
    NSString *_guid;
    NSArray *_chapters;
    NSString *_chaptersURL;
}

@property (nonatomic, retain) NSString *title;
/// The <pubDate> text as the feed wrote it, kept for display even when it
/// could not be parsed into -pubDate.
@property (nonatomic, retain) NSString *pubDateString;
/// Best-effort parse of pubDateString; nil if the feed used a format we
/// don't recognize.
@property (nonatomic, retain) NSDate *pubDate;
/// <itunes:duration> as the feed wrote it (seconds, or H:MM:SS, or MM:SS)
@property (nonatomic, retain) NSString *durationString;
@property (nonatomic, retain) NSString *summary;
/// <enclosure url="...">, the audio stream to play
@property (nonatomic, retain) NSString *streamURL;
/// <enclosure type="...">, e.g. "audio/mpeg"
@property (nonatomic, retain) NSString *mimeType;
@property (nonatomic, retain) NSString *guid;
/// Chapters read inline from the feed (Podlove Simple Chapters), in feed
/// order; nil if the feed had none. PodcastChapter objects.
@property (nonatomic, retain) NSArray *chapters;
/// Podcast Namespace <podcast:chapters url>: a JSON file of chapters to
/// fetch lazily, only used when -chapters is nil.
@property (nonatomic, retain) NSString *chaptersURL;

/// Duration formatted as H:MM:SS / M:SS for display, from whatever form
/// the feed used; the raw string if it cannot be normalized.
- (NSString *)formattedDuration;

@end

#endif /* PodcastEpisode_h */
