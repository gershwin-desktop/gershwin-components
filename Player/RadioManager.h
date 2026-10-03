/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef RadioManager_h
#define RadioManager_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "StreamPlayer.h"

@class RadioStation;
@class RadioManager;

@protocol RadioManagerDelegate <NSObject>
@optional
/// Station list was updated (initial load, search results)
- (void)radioManagerDidUpdateStations:(RadioManager *)manager;
/// Started playing a radio station
- (void)radioManagerDidStartPlaying:(RadioManager *)manager station:(RadioStation *)station;
/// Stopped playback
- (void)radioManagerDidStop:(RadioManager *)manager;
/// An error occurred
- (void)radioManager:(RadioManager *)manager didFailWithError:(NSString *)errorMessage;
/// Status text update (e.g., "Connecting...", "Buffering...")
- (void)radioManagerDidUpdateStatus:(RadioManager *)manager status:(NSString *)status;
/// A station icon was loaded from disk or network; the ItemFlowView should refresh
- (void)radioManager:(RadioManager *)manager didLoadIconAtIndex:(NSUInteger)index;
/// ICY metadata (radio text / StreamTitle) was updated during streaming
- (void)radioManager:(RadioManager *)manager didUpdateRadioText:(NSString *)radioText;
/// Full ICY metadata dictionary (StreamTitle, icy-url, etc.) was updated
- (void)radioManager:(RadioManager *)manager didUpdateMetadata:(NSDictionary *)metadata;
@end

/**
 * RadioManager
 *
 * Central coordinator for internet radio functionality.
 * Manages station discovery (via RadioBrowser), stream playback (via StreamPlayer),
 * station icon caching/prefetching, and communicates with the UI layer through
 * RadioManagerDelegate.
 *
 * Singleton - one instance serves the entire application.
 */
@interface RadioManager : NSObject <StreamPlayerDelegate>
{
@private
    StreamPlayer *_player;
    NSArray *_stations;               // RadioStation objects
    NSMutableDictionary *_stationImages;  // key: stationId → NSImage
    NSMutableDictionary *_placeholderImages;  // the same stand-in every time
    NSString *_currentStationName;
    NSString *_currentStreamURL;

    // Icon download / cache state
    NSMutableDictionary *_iconIndex;  // key: stationId → {filename, lastAccess, timestamp}
    NSString *_iconCachePath;
    NSMutableSet *_downloadingKeys;
    NSOperationQueue *_iconQueue;
    NSMutableSet *_fadingPlayers;    // stations fading out after a switch
    StreamPlayer *_outgoing;         // audible old station while the new one connects
    NSTimeInterval _fadeDuration;
    BOOL _connecting;
    NSUInteger _tuneAttempt;     // bumped by every new station and by -stop
    NSUInteger _listRequest;     // bumped by every station list asked for
    int _maxCacheEntries;
}

@property (nonatomic, assign) id<RadioManagerDelegate> delegate;
@property (nonatomic, readonly) BOOL isPlaying;
/// YES from choosing a station until it plays or fails
@property (nonatomic, readonly) BOOL isConnecting;
@property (nonatomic, readonly, copy) NSString *currentStationName;
@property (nonatomic, readonly, copy) NSString *currentStreamURL;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL muted;
/// How long stations fade in, out and into each other; 0 switches at once.
@property (nonatomic, assign) NSTimeInterval fadeDuration;
@property (nonatomic, readonly) NSArray *stations;
/// The player of the current station, nil while nothing is tuned in
@property (nonatomic, readonly) StreamPlayer *player;

+ (instancetype)sharedManager;

/// Fetch local stations from the radio directory service
- (void)loadLocalStations;

/// Search stations by query string
- (void)searchStations:(NSString *)query;

/// Begin streaming a station
- (void)playStation:(RadioStation *)station;

/// Stream an arbitrary URL directly
- (void)playURL:(NSString *)urlString;

/// Stop streaming; the sound fades out
- (void)stop;
/// A new player for each station; subclasses may configure it
- (StreamPlayer *)makePlayer;

/// Return the cached icon for a station, or nil if not yet loaded
- (NSImage *)imageForStation:(RadioStation *)station;

/// Start fetching a station's icon from the network
- (void)prefetchIconForStationAtIndex:(NSUInteger)index;

@end

#endif /* RadioManager_h */
