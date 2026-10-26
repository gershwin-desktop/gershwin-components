/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef Podcast_h
#define Podcast_h

#import <Foundation/Foundation.h>

/**
 * Podcast
 *
 * Model object representing a podcast show, as returned by the iTunes
 * Search API (a search result) or restored from a subscription saved in
 * the defaults.
 */
@interface Podcast : NSObject
{
@private
    NSString *_collectionId;
    NSString *_name;
    NSString *_artistName;
    NSString *_artworkURL;
    NSString *_feedURL;
    NSString *_genre;
}

/// iTunes "collectionId", unique per show
@property (nonatomic, retain) NSString *collectionId;
/// Show title ("collectionName")
@property (nonatomic, retain) NSString *name;
/// Publisher / host name ("artistName")
@property (nonatomic, retain) NSString *artistName;
/// Cover artwork URL ("artworkUrl600"/"artworkUrl100"/"artworkUrl60")
@property (nonatomic, retain) NSString *artworkURL;
/// RSS/Atom feed URL episodes are read from ("feedUrl")
@property (nonatomic, retain) NSString *feedURL;
/// Genre tag ("primaryGenreName")
@property (nonatomic, retain) NSString *genre;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

/// The show as a property list, to be kept in the defaults (subscriptions).
- (NSDictionary *)propertyList;
/// A show kept with -propertyList; nil if there is nothing to subscribe to.
+ (instancetype)podcastWithPropertyList:(NSDictionary *)plist;
/// Same iTunes collection, or the same feed when there is no collection id.
- (BOOL)isSamePodcastAs:(Podcast *)other;

@end

#endif /* Podcast_h */
