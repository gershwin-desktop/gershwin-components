/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerSession_h
#define PlayerSession_h

#import <Foundation/Foundation.h>
#import "StreamPlayer.h"
#import "PlayerPlaylist.h"

typedef id<MediaPlayback> (^PlayerMediaFactory)(void);

typedef NS_ENUM(NSInteger, PlayerSessionState) {
    PlayerSessionStopped,
    PlayerSessionPlaying,
    PlayerSessionPaused
};

@class PlayerSession;

/// All messages arrive on the main thread.
@protocol PlayerSessionDelegate <NSObject>
@optional
- (void)playerSessionDidChangeState:(PlayerSession *)session;
/// Another playlist item became the current one.
- (void)playerSessionDidChangeTrack:(PlayerSession *)session;
- (void)playerSession:(PlayerSession *)session didFailToOpenItem:(NSString *)item
                error:(NSError *)error;
- (void)playerSession:(PlayerSession *)session didDiscoverVideoWithWidth:(int)width
               height:(int)height;
- (void)playerSession:(PlayerSession *)session didDecodeVideoFrameData:(NSData *)rgbaData
                width:(int)width height:(int)height;
@end

/**
 * Playback of a playlist of local files and stream URLs: what Play/Pause,
 * Stop, Next, Previous and the end of a track do.  The window only shows
 * this state and forwards the user's commands.
 */
@interface PlayerSession : NSObject <StreamPlayerDelegate>
{
    id<MediaPlayback> _media;
    PlayerPlaylist *_playlist;
    PlayerSessionState _state;
    float _volume;
    BOOL _muted;
    id<PlayerSessionDelegate> _delegate;
    BOOL _opening;            // the current item has not started yet
    BOOL _skipping;           // items that fail to open are skipped
    NSUInteger _attemptsLeft; // bounds skipping to one pass over the list
    NSTimeInterval _fadeDuration;
    BOOL _pausePending;       // pausing once the fade-out is done
    NSUInteger _resumeIndex;  // a restored track continues at _resumePosition
    NSTimeInterval _resumePosition;
    PlayerMediaFactory _mediaFactory;
    NSMutableArray *_fadingMedia; // tracks fading out under the current one
    NSTimer *_endWatch;       // hands over to the next track before the end
}

@property (nonatomic, assign) id<PlayerSessionDelegate> delegate;
@property (nonatomic, readonly) PlayerPlaylist *playlist;
@property (nonatomic, readonly) PlayerSessionState state;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL muted;
/// How long pause, stop and resume fade, streams fade in and tracks
/// cross-fade; 0 does all that at once.  A track starting at its
/// beginning never fades in.
@property (nonatomic, assign) NSTimeInterval fadeDuration;
/// Makes the players for cross-fades: the next track plays in a new one
/// while the old one fades out.  Without it tracks change at once.
@property (nonatomic, copy) PlayerMediaFactory mediaFactory;

- (instancetype)initWithMedia:(id<MediaPlayback>)media;

/// Replaces the playlist and plays the first item that can be opened.
- (void)openItems:(NSArray *)items;
/// Appends to the playlist; starts playing them if nothing is playing.
- (void)addItems:(NSArray *)items;
/// Plays the given playlist item unless it is already the one playing.
/// Returns NO if there is no such item.
- (BOOL)playItemAtIndex:(NSUInteger)index;

/// The list, its current track, where in it and whether it plays, to
/// continue there later (a property list).
- (NSDictionary *)stateToRemember;
/// Brings back a list kept with -stateToRemember: playing again if it
/// played, otherwise stopped with its track chosen; a paused track
/// continues where it was when played.  Anything unreadable is ignored.
- (void)restoreState:(NSDictionary *)state;

- (void)togglePlayPause;
- (void)stop;
- (void)next;
/// Restarts the track when it has played a few seconds, else goes back one.
- (void)previous;
- (void)seekToTime:(NSTimeInterval)seconds;
- (void)skipBy:(NSTimeInterval)seconds;

/// YES while the current item is being opened (a stream connecting).
- (BOOL)isConnecting;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
- (BOOL)hasVideo;

- (BOOL)canPlay;
- (BOOL)canStop;
- (BOOL)canGoNext;
- (BOOL)canGoPrevious;
- (BOOL)canSeek;

@end

#endif /* PlayerSession_h */
