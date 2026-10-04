/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PodcastSearch.h"
#import "PlayerAsync.h"
#import "Podcast.h"

@interface PodcastSearch ()
{
@private
    NSString *_baseURL;
}
@end

@implementation PodcastSearch

+ (instancetype)sharedSearch
{
    static PodcastSearch *shared = nil;
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
        _baseURL = [@"https://itunes.apple.com/search" retain];
    }
    return self;
}

- (void)dealloc
{
    [_baseURL release];
    [super dealloc];
}

#pragma mark - Search

- (void)searchPodcasts:(NSString *)query
             completion:(void(^)(NSArray *podcasts, NSError *error))completion
{
    if ([query length] == 0) {
        if (completion) completion(@[], nil);
        return;
    }

    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@?", _baseURL];
    NSDictionary *params = @{
        @"media": @"podcast",
        @"entity": @"podcast",
        @"limit": @"50",
        @"term": query
    };
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in params) {
        NSString *val = [[params objectForKey:key] stringByAddingPercentEncodingWithAllowedCharacters:
                          [NSCharacterSet URLQueryAllowedCharacterSet]];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, val]];
    }
    [urlString appendString:[parts componentsJoinedByString:@"&"]];

    NSURL *url = [NSURL URLWithString:urlString];
    NSLog(@"[PodcastSearch] Request: %@", url);

    // In MRC: copy the completion block; it is released once it has run
    __block void(^savedCompletion)(NSArray *, NSError*) = [completion copy];

    PlayerRunInBackground(^{
        @autoreleasepool {
            NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:15.0];
            NSURLResponse *response = nil;
            NSError *connectionError = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&response
                                                             error:&connectionError];

            PlayerRunOnMainThread(^{
                @autoreleasepool {
                    if (connectionError) {
                        if (savedCompletion) {
                            savedCompletion(nil, connectionError);
                            [savedCompletion release];
                            savedCompletion = nil;
                        }
                        return;
                    }

                    NSError *jsonError = nil;
                    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
                    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                        if (savedCompletion) {
                            savedCompletion(nil, jsonError);
                            [savedCompletion release];
                            savedCompletion = nil;
                        }
                        return;
                    }

                    NSArray *results = [json objectForKey:@"results"];
                    NSMutableArray *podcasts = [NSMutableArray array];
                    if ([results isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *item in results) {
                            if (![item isKindOfClass:[NSDictionary class]]) continue;
                            if ([item objectForKey:@"feedUrl"] == nil) continue;
                            Podcast *podcast = [[Podcast alloc] initWithDictionary:item];
                            [podcasts addObject:podcast];
                            [podcast release];
                        }
                    }

                    if (savedCompletion) {
                        savedCompletion(podcasts, nil);
                        [savedCompletion release];
                        savedCompletion = nil;
                    }
                }
            });
        }
    });
}

@end
