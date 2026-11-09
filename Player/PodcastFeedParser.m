/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PodcastFeedParser.h"
#import "PlayerAsync.h"
#import "PodcastEpisode.h"
#import "PodcastChapter.h"

@interface PodcastFeedParser ()
{
@private
    NSMutableArray *_episodes;
    PodcastEpisode *_currentEpisode;
    NSMutableString *_currentText;
    NSString *_currentElement;
    BOOL _inItem;
    NSMutableArray *_currentChapters;   // Podlove Simple Chapters for _currentEpisode
}
@end

@implementation PodcastFeedParser

+ (void)fetchEpisodesForFeedURL:(NSString *)feedURL
                      completion:(void(^)(NSArray *episodes, NSError *error))completion
{
    NSURL *url = [NSURL URLWithString:feedURL ?: @""];
    if (!url) {
        if (completion) completion(nil, nil);
        return;
    }

    __block void(^savedCompletion)(NSArray *, NSError *) = [completion copy];

    PlayerRunInBackground(^{
        @autoreleasepool {
            NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:20.0];
            NSError *connectionError = nil;
            NSData *data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:NULL
                                                             error:&connectionError];

            NSArray *episodes = nil;
            if (data && !connectionError) {
                PodcastFeedParser *parser = [[PodcastFeedParser alloc] init];
                episodes = [[parser parseFeedData:data] retain];
                [parser release];
            }

            PlayerRunOnMainThread(^{
                @autoreleasepool {
                    if (savedCompletion) {
                        savedCompletion(episodes ?: @[], episodes ? nil : (connectionError ?: [NSError errorWithDomain:@"Podcast" code:1 userInfo:nil]));
                        [savedCompletion release];
                        savedCompletion = nil;
                    }
                    [episodes release];
                }
            });
        }
    });
}

- (void)dealloc
{
    [_episodes release];
    [_currentEpisode release];
    [_currentText release];
    [_currentElement release];
    [_currentChapters release];
    [super dealloc];
}

- (NSArray *)parseFeedData:(NSData *)data
{
    _episodes = [[NSMutableArray alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    [parser setDelegate:self];
    [parser parse];
    [parser release];
    return [[_episodes copy] autorelease];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName
     attributes:(NSDictionary *)attributeDict
{
    if ([elementName isEqualToString:@"item"]) {
        _inItem = YES;
        [_currentEpisode release];
        _currentEpisode = [[PodcastEpisode alloc] init];
        [_currentChapters release];
        _currentChapters = [[NSMutableArray alloc] init];
        return;
    }
    if (!_inItem) {
        return;
    }
    if ([elementName isEqualToString:@"enclosure"]) {
        [_currentEpisode setStreamURL:[attributeDict objectForKey:@"url"]];
        [_currentEpisode setMimeType:[attributeDict objectForKey:@"type"]];
        return;
    }
    // Podlove Simple Chapters: inline, one self-closing element per chapter
    if ([elementName isEqualToString:@"psc:chapter"]) {
        NSTimeInterval start = [PodcastChapter
            secondsFromPSCTimeString:[attributeDict objectForKey:@"start"]];
        NSString *title = [attributeDict objectForKey:@"title"] ?: @"";
        PodcastChapter *chapter = [[PodcastChapter alloc] initWithTitle:title startTime:start];
        [_currentChapters addObject:chapter];
        [chapter release];
        return;
    }
    // Podcast Namespace: a URL to a separate chapters JSON file, fetched
    // lazily (only when the feed has no inline psc:chapters) when the
    // episode is actually played
    if ([elementName isEqualToString:@"podcast:chapters"]) {
        [_currentEpisode setChaptersURL:[attributeDict objectForKey:@"url"]];
        return;
    }
    [_currentElement release];
    _currentElement = [elementName copy];
    [_currentText release];
    _currentText = [[NSMutableString alloc] init];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (_inItem && _currentText) {
        [_currentText appendString:string];
    }
}

// Feeds commonly wrap <description>/<itunes:summary> in <![CDATA[...]]> -
// NSXMLParser delivers that through this callback instead of
// -foundCharacters:, as raw bytes, not through -foundCharacters: at all.
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock
{
    if (!_inItem || !_currentText) {
        return;
    }
    NSString *text = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (text) {
        [_currentText appendString:text];
        [text release];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName
{
    if ([elementName isEqualToString:@"item"]) {
        if ([_currentChapters count] > 0) {
            // Chapters must stay in time order regardless of how the feed
            // wrote them
            [_currentChapters sortUsingComparator:^NSComparisonResult(PodcastChapter *a, PodcastChapter *b) {
                if ([a startTime] < [b startTime]) return NSOrderedAscending;
                if ([a startTime] > [b startTime]) return NSOrderedDescending;
                return NSOrderedSame;
            }];
            [_currentEpisode setChapters:_currentChapters];
        }
        [_currentChapters release];
        _currentChapters = nil;
        if ([_currentEpisode streamURL] != nil) {
            [_episodes addObject:_currentEpisode];
        }
        [_currentEpisode release];
        _currentEpisode = nil;
        _inItem = NO;
        return;
    }
    if (!_inItem || _currentText == nil) {
        return;
    }

    NSString *text = [_currentText stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([elementName isEqualToString:@"title"]) {
        [_currentEpisode setTitle:text];
    } else if ([elementName isEqualToString:@"pubDate"]) {
        [_currentEpisode setPubDateString:text];
        [_currentEpisode setPubDate:[self dateFromRFC2822String:text]];
    } else if ([elementName isEqualToString:@"guid"]) {
        [_currentEpisode setGuid:text];
    } else if ([elementName isEqualToString:@"itunes:duration"]) {
        [_currentEpisode setDurationString:text];
    } else if ([elementName isEqualToString:@"itunes:summary"]) {
        [_currentEpisode setSummary:text];
    } else if ([elementName isEqualToString:@"description"] && [[_currentEpisode summary] length] == 0) {
        [_currentEpisode setSummary:text];
    }

    [_currentElement release];
    _currentElement = nil;
    [_currentText release];
    _currentText = nil;
}

// Feeds write pubDate as RFC 2822 ("Tue, 01 Oct 2024 12:00:00 +0000" or
// "... GMT"); try the numeric-offset form first, then the zone-name form.
- (NSDate *)dateFromRFC2822String:(NSString *)string
{
    if ([string length] == 0) {
        return nil;
    }
    static NSDateFormatter *numericOffsetFormatter = nil;
    static NSDateFormatter *zoneNameFormatter = nil;
    if (!numericOffsetFormatter) {
        numericOffsetFormatter = [[NSDateFormatter alloc] init];
        [numericOffsetFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
        [numericOffsetFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss ZZZ"];

        zoneNameFormatter = [[NSDateFormatter alloc] init];
        [zoneNameFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
        [zoneNameFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss zzz"];
    }
    NSDate *date = [numericOffsetFormatter dateFromString:string];
    if (!date) {
        date = [zoneNameFormatter dateFromString:string];
    }
    return date;
}

@end
