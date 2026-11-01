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
#import "PlayerPlaybackMachine.h"

typedef id<MediaPlayback> (^PlayerMediaFactory)(void);

@class PlayerSession;

/// All messages arrive on the main thread.
@protocol PlayerSessionDelegate <NSObject>
@optional
- (void)playerSessionDidChangeState:(PlayerSession *)session;
/// Another playlist item became the current one.
- (void)playerSessionDidChangeTrack:(PlayerSession *)session;
/// userOpened: the user opened it (Open, a drop) and deserves an alert;
/// otherwise the failure is shown in the window only (lastError).  Sent
/// once the transition is committed; an alert must still not be run from
/// here, as it would spin the run loop inside the session's effects.
- (void)playerSession:(PlayerSession *)session didFailToOpenItem:(NSString *)item
                error:(NSError *)error userOpened:(BOOL)userOpened;
- (void)playerSession:(PlayerSession *)session didDiscoverVideoWithWidth:(int)width
               height:(int)height;
- (void)playerSession:(PlayerSession *)session didDecodeVideoFrameData:(NSData *)rgbaData
                width:(int)width height:(int)height;
/// ICY metadata of the stream that plays (StreamTitle and the like).
- (void)playerSession:(PlayerSession *)session didUpdateMetadata:(NSDictionary *)metadata;
@end

/**
 * Playback of a playlist of local files and stream URLs.  What Play/Pause,
 * Stop, Next, Previous and the end of a track do is decided by its
 * PlayerPlaybackMachine; the session turns the user's commands and the
 * media player's messages into its events and carries out the effects it
 * answers with.  The window only shows this state and forwards commands.
 */
@interface PlayerSession : NSObject <StreamPlayerDelegate>
{
    id<MediaPlayback> _media;
    PlayerPlaybackMachine *_machine;
    float _volume;
    BOOL _muted;
    id<PlayerSessionDelegate> _delegate;
    NSTimeInterval _fadeDuration;
    PlayerMediaFactory _mediaFactory;
    NSMutableArray *_fadingMedia; // tracks fading out under the current one
    // Audible while the next item opens; it fades out once that one plays
    // (or fails, or is stopped), so a slow stream does not leave a gap
    id<MediaPlayback> _outgoing;
    BOOL _fadesInEveryItem;
    NSTimer *_endWatch;       // hands over to the next track before the end
    NSUInteger _mediaGeneration;  // the machine's generation _media was opened with
    // Events that came in while the effects of another were carried out
    // (a media player reporting before -playURL: returns): handled after
    NSMutableArray *_queuedEvents;
    BOOL _handling;
}

@property (nonatomic, assign) id<PlayerSessionDelegate> delegate;
@property (nonatomic, readonly) PlayerPlaylist *playlist;
@property (nonatomic, readonly) PlayerPlaybackState state;
/// The last failure, of an item or of the audio output (model data).
@property (nonatomic, readonly) NSError *lastError;
/// The playing stream ran dry and waits for data.
@property (nonatomic, readonly) BOOL isBuffering;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL muted;
/// How long pause, stop and resume fade, streams fade in and tracks
/// cross-fade; 0 does all that at once.  A track starting at its
/// beginning never fades in.
@property (nonatomic, assign) NSTimeInterval fadeDuration;
/// Makes the players for cross-fades: the next track plays in a new one
/// while the old one fades out.  Without it tracks change at once.
@property (nonatomic, copy) PlayerMediaFactory mediaFactory;
/// Every item is joined live, in the middle (radio): each fades in once it
/// plays.  Otherwise only stream URLs do; a track starts at full volume.
@property (nonatomic, assign) BOOL fadesInEveryItem;
/// The player of the current item.
@property (nonatomic, readonly) id<MediaPlayback> media;

- (instancetype)initWithMedia:(id<MediaPlayback>)media;

/// Replaces the playlist with what the user opened and plays the first item
/// that can be opened.
- (void)openItems:(NSArray *)items;
/// Appends what the user added (a drop) to the playlist; starts playing it
/// if nothing is playing.
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
/// Pause was pressed while opening: the item lands paused once open.
- (BOOL)isPausePending;
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
