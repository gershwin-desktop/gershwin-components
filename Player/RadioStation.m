/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "RadioStation.h"

@implementation RadioStation

@synthesize stationId = _stationId;
@synthesize name = _name;
@synthesize subtext = _subtext;
@synthesize imageURL = _imageURL;
@synthesize tuneURL = _tuneURL;
@synthesize streamURL = _streamURL;

- (instancetype)initWithDictionary:(NSDictionary *)dict
{
    self = [super init];
    if (self) {
        _name = [[dict objectForKey:@"text"] copy];
        _subtext = [[dict objectForKey:@"subtext"] copy];

        // Try multiple keys for images - TuneIn API can vary
        _imageURL = [[dict objectForKey:@"image"] copy];
        if (!_imageURL) _imageURL = [[dict objectForKey:@"logo"] copy];
        if (!_imageURL) _imageURL = [[dict objectForKey:@"image_url"] copy];
        if (!_imageURL) _imageURL = [[dict objectForKey:@"@image"] copy];

        _tuneURL = [[dict objectForKey:@"URL"] copy];
        _stationId = [[dict objectForKey:@"guide_id"] copy];

        // Sometimes ID is in 'now_playing_id' or 'preset_id'
        if (!_stationId) _stationId = [[dict objectForKey:@"preset_id"] copy];
    }
    return self;
}

- (NSDictionary *)propertyList
{
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    [plist setValue:_stationId forKey:@"stationId"];
    [plist setValue:_name forKey:@"name"];
    [plist setValue:_subtext forKey:@"subtext"];
    [plist setValue:_imageURL forKey:@"imageURL"];
    [plist setValue:_tuneURL forKey:@"tuneURL"];
    [plist setValue:_streamURL forKey:@"streamURL"];
    return plist;
}

+ (instancetype)stationWithPropertyList:(NSDictionary *)plist
{
    if (![plist isKindOfClass:[NSDictionary class]]
        || ([plist objectForKey:@"tuneURL"] == nil && [plist objectForKey:@"streamURL"] == nil)) {
        return nil;
    }
    RadioStation *station = [[[self alloc] init] autorelease];
    [station setStationId:[plist objectForKey:@"stationId"]];
    [station setName:[plist objectForKey:@"name"]];
    [station setSubtext:[plist objectForKey:@"subtext"]];
    [station setImageURL:[plist objectForKey:@"imageURL"]];
    [station setTuneURL:[plist objectForKey:@"tuneURL"]];
    [station setStreamURL:[plist objectForKey:@"streamURL"]];
    return station;
}

- (BOOL)isSameStationAs:(RadioStation *)other
{
    if (other == nil) {
        return NO;
    }
    if (_stationId || [other stationId]) {
        return [_stationId isEqualToString:[other stationId]];
    }
    NSString *mine = _streamURL ?: _tuneURL;
    NSString *theirs = [other streamURL] ?: [other tuneURL];
    return mine != nil && [mine isEqualToString:theirs];
}

- (void)dealloc
{
    [_stationId release];
    [_name release];
    [_subtext release];
    [_imageURL release];
    [_tuneURL release];
    [_streamURL release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<RadioStation: %@ (%@)>", _name, _stationId];
}

@end
