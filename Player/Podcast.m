/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "Podcast.h"

@implementation Podcast

@synthesize collectionId = _collectionId;
@synthesize name = _name;
@synthesize artistName = _artistName;
@synthesize artworkURL = _artworkURL;
@synthesize feedURL = _feedURL;
@synthesize genre = _genre;

- (instancetype)initWithDictionary:(NSDictionary *)dict
{
    self = [super init];
    if (self) {
        id collectionId = [dict objectForKey:@"collectionId"];
        _collectionId = [[collectionId description] copy];
        _name = [[dict objectForKey:@"collectionName"] copy];
        _artistName = [[dict objectForKey:@"artistName"] copy];

        // Largest artwork first; the API does not always include every size
        _artworkURL = [[dict objectForKey:@"artworkUrl600"] copy];
        if (!_artworkURL) _artworkURL = [[dict objectForKey:@"artworkUrl100"] copy];
        if (!_artworkURL) _artworkURL = [[dict objectForKey:@"artworkUrl60"] copy];
        if (!_artworkURL) _artworkURL = [[dict objectForKey:@"artworkUrl30"] copy];

        _feedURL = [[dict objectForKey:@"feedUrl"] copy];
        _genre = [[dict objectForKey:@"primaryGenreName"] copy];
    }
    return self;
}

- (NSDictionary *)propertyList
{
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    [plist setValue:_collectionId forKey:@"collectionId"];
    [plist setValue:_name forKey:@"name"];
    [plist setValue:_artistName forKey:@"artistName"];
    [plist setValue:_artworkURL forKey:@"artworkURL"];
    [plist setValue:_feedURL forKey:@"feedURL"];
    [plist setValue:_genre forKey:@"genre"];
    return plist;
}

+ (instancetype)podcastWithPropertyList:(NSDictionary *)plist
{
    if (![plist isKindOfClass:[NSDictionary class]] || [plist objectForKey:@"feedURL"] == nil) {
        return nil;
    }
    Podcast *podcast = [[[self alloc] init] autorelease];
    [podcast setCollectionId:[plist objectForKey:@"collectionId"]];
    [podcast setName:[plist objectForKey:@"name"]];
    [podcast setArtistName:[plist objectForKey:@"artistName"]];
    [podcast setArtworkURL:[plist objectForKey:@"artworkURL"]];
    [podcast setFeedURL:[plist objectForKey:@"feedURL"]];
    [podcast setGenre:[plist objectForKey:@"genre"]];
    return podcast;
}

- (BOOL)isSamePodcastAs:(Podcast *)other
{
    if (other == nil) {
        return NO;
    }
    if (_collectionId || [other collectionId]) {
        return [_collectionId isEqualToString:[other collectionId]];
    }
    return _feedURL != nil && [_feedURL isEqualToString:[other feedURL]];
}

- (void)dealloc
{
    [_collectionId release];
    [_name release];
    [_artistName release];
    [_artworkURL release];
    [_feedURL release];
    [_genre release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<Podcast: %@ (%@)>", _name, _collectionId];
}

@end
