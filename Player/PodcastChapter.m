/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PodcastChapter.h"
#import "PlayerAsync.h"

@implementation PodcastChapter

@synthesize title = _title;
@synthesize startTime = _startTime;

- (instancetype)initWithTitle:(NSString *)title startTime:(NSTimeInterval)startTime
{
    self = [super init];
    if (self) {
        _title = [title copy];
        _startTime = startTime;
    }
    return self;
}

- (void)dealloc
{
    [_title release];
    [super dealloc];
}

// "HH:MM:SS.mmm", "MM:SS.mmm" or plain seconds: Horner's method in base 60
// handles any of those with the same loop.
+ (NSTimeInterval)secondsFromPSCTimeString:(NSString *)string
{
    if ([string length] == 0) {
        return 0;
    }
    double seconds = 0;
    for (NSString *part in [string componentsSeparatedByString:@":"]) {
        seconds = seconds * 60.0 + [part doubleValue];
    }
    return seconds;
}

+ (void)fetchChaptersFromURL:(NSString *)url
                   completion:(void(^)(NSArray *chapters, NSError *error))completion
{
    NSURL *nsurl = [NSURL URLWithString:url ?: @""];
    if (!nsurl) {
        if (completion) completion(nil, nil);
        return;
    }

    __block void(^savedCompletion)(NSArray *, NSError *) = [completion copy];

    PlayerRunInBackground(^{
        @autoreleasepool {
            NSURLRequest *request = [NSURLRequest requestWithURL:nsurl
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:15.0];
            NSError *connectionError = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:NULL
                                                             error:&connectionError];

            NSArray *chapters = nil;
            if (data && !connectionError) {
                NSError *jsonError = nil;
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                NSArray *items = [json isKindOfClass:[NSDictionary class]]
                    ? [json objectForKey:@"chapters"] : nil;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSMutableArray *parsed = [NSMutableArray array];
                    for (NSDictionary *item in items) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        id startTime = [item objectForKey:@"startTime"];
                        NSString *title = [item objectForKey:@"title"];
                        PodcastChapter *chapter = [[PodcastChapter alloc]
                            initWithTitle:title ?: @"" startTime:[startTime doubleValue]];
                        [parsed addObject:chapter];
                        [chapter release];
                    }
                    chapters = parsed;
                }
            }

            PlayerRunOnMainThread(^{
                @autoreleasepool {
                    if (savedCompletion) {
                        savedCompletion(chapters, chapters ? nil : connectionError);
                        [savedCompletion release];
                        savedCompletion = nil;
                    }
                }
            });
        }
    });
}

@end
