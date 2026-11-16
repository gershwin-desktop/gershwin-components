/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PodcastEpisode.h"

@implementation PodcastEpisode

@synthesize title = _title;
@synthesize pubDateString = _pubDateString;
@synthesize pubDate = _pubDate;
@synthesize durationString = _durationString;
@synthesize summary = _summary;
@synthesize streamURL = _streamURL;
@synthesize mimeType = _mimeType;
@synthesize guid = _guid;
@synthesize chapters = _chapters;
@synthesize chaptersURL = _chaptersURL;

- (void)dealloc
{
    [_title release];
    [_pubDateString release];
    [_pubDate release];
    [_durationString release];
    [_summary release];
    [_streamURL release];
    [_mimeType release];
    [_guid release];
    [_chapters release];
    [_chaptersURL release];
    [super dealloc];
}

// <itunes:duration> is written as plain seconds by some feeds and as
// H:MM:SS / MM:SS by others; only the plain-seconds form needs converting.
- (NSString *)formattedDuration
{
    if ([_durationString length] == 0) {
        return @"";
    }
    if ([_durationString rangeOfString:@":"].location != NSNotFound) {
        return _durationString;
    }

    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([_durationString rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return _durationString;
    }

    long long totalSeconds = [_durationString longLongValue];
    long long hours = totalSeconds / 3600;
    long long minutes = (totalSeconds % 3600) / 60;
    long long seconds = totalSeconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%lld:%02lld:%02lld", hours, minutes, seconds];
    }
    return [NSString stringWithFormat:@"%lld:%02lld", minutes, seconds];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<PodcastEpisode: %@>", _title];
}

@end
