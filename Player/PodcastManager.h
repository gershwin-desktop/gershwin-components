/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PodcastManager_h
#define PodcastManager_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class Podcast;
@class PodcastEpisode;
@class PodcastManager;

@protocol PodcastManagerDelegate <NSObject>
@optional
/// Search results were updated (or cleared, for an empty query)
- (void)podcastManagerDidUpdateSearchResults:(PodcastManager *)manager;
/// The subscription list changed (subscribe/unsubscribe, or loaded at launch)
- (void)podcastManagerDidUpdateSubscriptions:(PodcastManager *)manager;
/// Episodes for -selectShow: arrived (or failed); episodes is nil on error
- (void)podcastManager:(PodcastManager *)manager
   didUpdateEpisodesForShow:(Podcast *)show
                   episodes:(NSArray *)episodes
                      error:(NSString *)error;
/// Status text update (e.g., "Searching...", "23 podcasts")
- (void)podcastManagerDidUpdateStatus:(PodcastManager *)manager status:(NSString *)status;
/// A show's artwork was loaded from the network; the caller's list view
/// should refresh the item at this index.
- (void)podcastManager:(PodcastManager *)manager didLoadArtworkAtIndex:(NSUInteger)index;
@end

/**
 * PodcastManager
 *
 * Central coordinator for podcast search and subscriptions. Searches via
 * PodcastSearch (iTunes Search API), reads episode lists from a show's own
 * feed via PodcastFeedParser, and keeps subscriptions in the defaults.
 * Episode playback itself goes through RadioManager, which already streams
 * an arbitrary URL - podcasts are stream-only, there is no downloading.
 */
@interface PodcastManager : NSObject
{
@private
    NSArray *_searchResults;      // Podcast objects
    NSMutableArray *_subscriptions;  // Podcast objects, persisted
    Podcast *_currentShow;
    NSArray *_episodes;            // PodcastEpisode objects, for _currentShow
    NSMutableDictionary *_episodeCache;  // feedURL -> NSArray of PodcastEpisode, this session only
    NSMutableDictionary *_artworkImages; // key -> NSImage
    NSMutableSet *_downloadingArtworkKeys;
    NSOperationQueue *_artworkQueue;
    NSUInteger _episodeFetchAttempt;  // bumped by every -selectShow: and -clearSelectedShow
    NSMutableSet *_playedEpisodeIdentifiers;  // guid (or streamURL), persisted
}

@property (nonatomic, assign) id<PodcastManagerDelegate> delegate;
@property (nonatomic, readonly) NSArray *searchResults;
@property (nonatomic, readonly) NSArray *subscriptions;
@property (nonatomic, readonly) Podcast *currentShow;
@property (nonatomic, readonly) NSArray *episodes;

+ (instancetype)sharedManager;

/// Search podcasts by query string; an empty query clears the results.
- (void)searchPodcasts:(NSString *)query;

- (void)subscribeToPodcast:(Podcast *)podcast;
- (void)unsubscribeFromPodcast:(Podcast *)podcast;
- (BOOL)isSubscribed:(Podcast *)podcast;

/// Read (and cache) the show's episode list from its feed.
- (void)selectShow:(Podcast *)podcast;
/// Back to the Shows screen: forgets the current show and its episodes.
- (void)clearSelectedShow;

/// Return the cached artwork for a show, or nil if not yet loaded.
- (NSImage *)imageForPodcast:(Podcast *)podcast;
/// Start fetching a show's artwork from the network.
- (void)prefetchArtworkForPodcast:(Podcast *)podcast atIndex:(NSUInteger)index;

/// YES once -markEpisodePlayed: has been called for this episode (identified
/// by guid, falling back to streamURL), in this or an earlier session.
- (BOOL)isEpisodePlayed:(PodcastEpisode *)episode;
/// Records that playback of this episode has started, persisted across
/// launches - the "oldest unplayed" auto-play preference reads this.
- (void)markEpisodePlayed:(PodcastEpisode *)episode;

@end

#endif /* PodcastManager_h */
