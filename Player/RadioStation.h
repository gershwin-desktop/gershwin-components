/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef RadioStation_h
#define RadioStation_h

#import <Foundation/Foundation.h>

/**
 * RadioStation
 *
 * Model object representing an internet radio station.
 * Encapsulates the data returned by the radio directory service (e.g., TuneIn).
 */
@interface RadioStation : NSObject
{
@private
    NSString *_stationId;
    NSString *_name;
    NSString *_subtext;
    NSString *_imageURL;
    NSString *_tuneURL;
    NSString *_streamURL;
}

/// Unique identifier from the directory service
@property (nonatomic, retain) NSString *stationId;
/// Human-readable station name
@property (nonatomic, retain) NSString *name;
/// Subtitle / genre tag (e.g. "Rock", "Local")
@property (nonatomic, retain) NSString *subtext;
/// URL for the station's logo/icon image
@property (nonatomic, retain) NSString *imageURL;
/// TuneIn playlist/tune URL (resolved to streamURL before playback)
@property (nonatomic, retain) NSString *tuneURL;
/// Resolved audio stream URL (may be filled after resolution)
@property (nonatomic, retain) NSString *streamURL;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

/// The station as a property list, to be kept in the defaults.
- (NSDictionary *)propertyList;
/// A station kept with -propertyList; nil if there is nothing to tune in.
+ (instancetype)stationWithPropertyList:(NSDictionary *)plist;
/// Same directory entry, or the same stream when there is no id.
- (BOOL)isSameStationAs:(RadioStation *)other;

@end

#endif /* RadioStation_h */
