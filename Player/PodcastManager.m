/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PodcastManager.h"
#import "PlayerAsync.h"
#import "Podcast.h"
#import "PodcastEpisode.h"
#import "PodcastSearch.h"
#import "PodcastFeedParser.h"

static NSString *const kPodcastSubscriptionsDefaultsKey = @"PlayerPodcastSubscriptions";
static NSString *const kPodcastPlayedEpisodesDefaultsKey = @"PlayerPodcastPlayedEpisodes";

@implementation PodcastManager

@synthesize delegate = _delegate;
@synthesize searchResults = _searchResults;
@synthesize currentShow = _currentShow;
@synthesize episodes = _episodes;

+ (instancetype)sharedManager
{
    static PodcastManager *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[self alloc] init];
        }
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _searchResults = [[NSArray alloc] init];
        _episodeCache = [[NSMutableDictionary alloc] init];
        _artworkImages = [[NSMutableDictionary alloc] init];
        _downloadingArtworkKeys = [[NSMutableSet alloc] init];
        _artworkQueue = [[NSOperationQueue alloc] init];
        [_artworkQueue setMaxConcurrentOperationCount:3];
        _playedEpisodeIdentifiers = [[NSMutableSet alloc] initWithArray:
            [[NSUserDefaults standardUserDefaults] arrayForKey:kPodcastPlayedEpisodesDefaultsKey] ?: @[]];
        [self loadSubscriptions];
    }
    return self;
}

- (void)dealloc
{
    [_searchResults release];
    [_subscriptions release];
    [_currentShow release];
    [_episodes release];
    [_episodeCache release];
    [_artworkImages release];
    [_downloadingArtworkKeys release];
    [_artworkQueue cancelAllOperations];
    [_artworkQueue release];
    [_playedEpisodeIdentifiers release];
    [super dealloc];
}

- (NSArray *)subscriptions
{
    return _subscriptions;
}

#pragma mark - Subscriptions

- (void)loadSubscriptions
{
    NSArray *plists = [[NSUserDefaults standardUserDefaults] arrayForKey:kPodcastSubscriptionsDefaultsKey];
    NSMutableArray *podcasts = [[NSMutableArray alloc] init];
    for (NSDictionary *plist in plists) {
        Podcast *podcast = [Podcast podcastWithPropertyList:plist];
        if (podcast) {
            [podcasts addObject:podcast];
        }
    }
    [_subscriptions release];
    _subscriptions = podcasts;
}

- (void)saveSubscriptions
{
    NSMutableArray *plists = [NSMutableArray array];
    for (Podcast *podcast in _subscriptions) {
        [plists addObject:[podcast propertyList]];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:plists forKey:kPodcastSubscriptionsDefaultsKey];
    [defaults synchronize];
}

- (BOOL)isSubscribed:(Podcast *)podcast
{
    for (Podcast *existing in _subscriptions) {
        if ([existing isSamePodcastAs:podcast]) {
            return YES;
        }
    }
    return NO;
}

- (void)subscribeToPodcast:(Podcast *)podcast
{
    if (!podcast || [self isSubscribed:podcast]) {
        return;
    }
    [_subscriptions addObject:podcast];
    [self saveSubscriptions];
    if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateSubscriptions:)]) {
        [_delegate podcastManagerDidUpdateSubscriptions:self];
    }
}

- (void)unsubscribeFromPodcast:(Podcast *)podcast
{
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < [_subscriptions count]; i++) {
        if ([[_subscriptions objectAtIndex:i] isSamePodcastAs:podcast]) {
            index = i;
            break;
        }
    }
    if (index == NSNotFound) {
        return;
    }
    [_subscriptions removeObjectAtIndex:index];
    [self saveSubscriptions];
    if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateSubscriptions:)]) {
        [_delegate podcastManagerDidUpdateSubscriptions:self];
    }
}

#pragma mark - Search

- (void)searchPodcasts:(NSString *)query
{
    if ([query length] == 0) {
        [_searchResults release];
        _searchResults = [[NSArray alloc] init];
        if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateSearchResults:)]) {
            [_delegate podcastManagerDidUpdateSearchResults:self];
        }
        return;
    }

    if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateStatus:status:)]) {
        [_delegate podcastManagerDidUpdateStatus:self status:[NSString stringWithFormat:@"Searching: %@", query]];
    }

    [[PodcastSearch sharedSearch] searchPodcasts:query completion:^(NSArray *podcasts, NSError *error) {
        if (!podcasts) {
            if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateStatus:status:)]) {
                [_delegate podcastManagerDidUpdateStatus:self status:
                    [error localizedDescription] ?: @"Search failed"];
            }
            return;
        }
        [_searchResults release];
        _searchResults = [podcasts retain];
        if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateSearchResults:)]) {
            [_delegate podcastManagerDidUpdateSearchResults:self];
        }
        if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateStatus:status:)]) {
            [_delegate podcastManagerDidUpdateStatus:self status:
                [NSString stringWithFormat:@"%tu podcasts", [podcasts count]]];
        }
    }];
}

#pragma mark - Episodes

- (void)selectShow:(Podcast *)podcast
{
    if (!podcast || [podcast feedURL] == nil) {
        return;
    }
    [_currentShow release];
    _currentShow = [podcast retain];
    NSUInteger attempt = ++_episodeFetchAttempt;

    NSArray *cached = [_episodeCache objectForKey:[podcast feedURL]];
    if (cached) {
        [_episodes release];
        _episodes = [cached retain];
        if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManager:didUpdateEpisodesForShow:episodes:error:)]) {
            [_delegate podcastManager:self didUpdateEpisodesForShow:podcast episodes:cached error:nil];
        }
        return;
    }

    if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManagerDidUpdateStatus:status:)]) {
        [_delegate podcastManagerDidUpdateStatus:self status:@"Loading episodes..."];
    }

    [PodcastFeedParser fetchEpisodesForFeedURL:[podcast feedURL] completion:^(NSArray *episodes, NSError *error) {
        if (attempt != self->_episodeFetchAttempt) {
            return;   // a different show was selected meanwhile
        }
        if (episodes) {
            [self->_episodeCache setObject:episodes forKey:[podcast feedURL]];
            [self->_episodes release];
            self->_episodes = [episodes retain];
        }
        if (_delegate != nil && [_delegate respondsToSelector:@selector(podcastManager:didUpdateEpisodesForShow:episodes:error:)]) {
            [_delegate podcastManager:self didUpdateEpisodesForShow:podcast episodes:episodes
                                  error:episodes ? nil : ([error localizedDescription] ?: @"Could not load episodes")];
        }
    }];
}

- (void)clearSelectedShow
{
    ++_episodeFetchAttempt;
    [_currentShow release];
    _currentShow = nil;
    [_episodes release];
    _episodes = nil;
}

#pragma mark - Artwork

- (NSString *)keyForPodcast:(Podcast *)podcast
{
    return [podcast collectionId] ?: [podcast feedURL];
}

- (NSImage *)imageForPodcast:(Podcast *)podcast
{
    if (!podcast) return nil;
    NSString *key = [self keyForPodcast:podcast];
    if (!key) return nil;
    NSImage *image = [_artworkImages objectForKey:key];
    if (image) return image;
    return [self textPlaceholderForPodcast:podcast];
}

- (NSImage *)textPlaceholderForPodcast:(Podcast *)podcast
{
    NSString *name = [podcast name] ?: @"Podcast";
    NSSize size = NSMakeSize(200, 200);

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    [[NSColor colorWithCalibratedWhite:0.25 alpha:1.0] setFill];
    [NSBezierPath fillRect:NSMakeRect(0, 0, size.width, size.height)];

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    [para setAlignment:NSTextAlignmentCenter];
    [para setLineBreakMode:NSLineBreakByTruncatingTail];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:15.0],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: para
    };
    [para release];

    NSAttributedString *as = [[NSAttributedString alloc] initWithString:name attributes:attrs];
    NSRect textRect = NSMakeRect(12, size.height / 2.0 - 30, size.width - 24, 60);
    [as drawInRect:textRect];
    [as release];

    [image unlockFocus];
    [image autorelease];
    return image;
}

- (void)prefetchArtworkForPodcast:(Podcast *)podcast atIndex:(NSUInteger)index
{
    if (!podcast) return;
    NSString *key = [self keyForPodcast:podcast];
    if (!key) return;
    if ([_artworkImages objectForKey:key]) return;

    @synchronized(_downloadingArtworkKeys) {
        if ([_downloadingArtworkKeys containsObject:key]) return;
        [_downloadingArtworkKeys addObject:key];
    }

    NSString *urlString = [podcast artworkURL];
    if (!urlString || [urlString length] == 0) {
        @synchronized(_downloadingArtworkKeys) {
            [_downloadingArtworkKeys removeObject:key];
        }
        return;
    }

    [_artworkQueue addOperationWithBlock:^{
        @autoreleasepool {
            NSURL *url = [NSURL URLWithString:urlString];
            NSData *data = nil;
            if (url) {
                NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                     timeoutInterval:15.0];
                data = [NSURLConnection sendSynchronousRequest:request returningResponse:NULL error:NULL];
            }

            PlayerRunOnMainThread(^{
                if (data) {
                    NSImage *image = [[NSImage alloc] initWithData:data];
                    if (image) {
                        [self->_artworkImages setObject:image forKey:key];
                        [image release];
                        if (self->_delegate != nil &&
                            [self->_delegate respondsToSelector:@selector(podcastManager:didLoadArtworkAtIndex:)]) {
                            [self->_delegate podcastManager:self didLoadArtworkAtIndex:index];
                        }
                    }
                }
                @synchronized(self->_downloadingArtworkKeys) {
                    [self->_downloadingArtworkKeys removeObject:key];
                }
            });
        }
    }];
}

#pragma mark - Played episodes

- (NSString *)identifierForEpisode:(PodcastEpisode *)episode
{
    return [episode guid] ?: [episode streamURL];
}

- (BOOL)isEpisodePlayed:(PodcastEpisode *)episode
{
    NSString *identifier = [self identifierForEpisode:episode];
    return identifier != nil && [_playedEpisodeIdentifiers containsObject:identifier];
}

- (void)markEpisodePlayed:(PodcastEpisode *)episode
{
    NSString *identifier = [self identifierForEpisode:episode];
    if (identifier == nil || [_playedEpisodeIdentifiers containsObject:identifier]) {
        return;
    }
    [_playedEpisodeIdentifiers addObject:identifier];
    [[NSUserDefaults standardUserDefaults] setObject:[_playedEpisodeIdentifiers allObjects]
                                              forKey:kPodcastPlayedEpisodesDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
