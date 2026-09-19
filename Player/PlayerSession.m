/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerSession.h"

// Previous restarts the track after this many seconds, like CD players do
static const NSTimeInterval kRestartThreshold = 3.0;

@implementation PlayerSession

@synthesize delegate = _delegate;
@synthesize playlist = _playlist;
@synthesize state = _state;

- (instancetype)initWithMedia:(id<MediaPlayback>)media
{
    self = [super init];
    if (self) {
        _media = [media retain];
        [_media setDelegate:self];
        _playlist = [[PlayerPlaylist alloc] init];
        _volume = 1.0f;
        _state = PlayerSessionStopped;
    }
    return self;
}

- (void)dealloc
{
    [_media setDelegate:nil];
    [_media close];
    [_media release];
    [_playlist release];
    [super dealloc];
}

#pragma mark - Volume

- (float)volume
{
    return _volume;
}

- (void)setVolume:(float)volume
{
    _volume = MAX(0.0f, MIN(1.0f, volume));
    [_media setVolume:_volume];
}

- (BOOL)muted
{
    return _muted;
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    [_media setMuted:muted];
}

#pragma mark - Playlist

- (void)openItems:(NSArray *)items
{
    [self closeMedia];
    [_playlist removeAllItems];
    [self appendItems:items];
    [self playFromIndex:[_playlist indexAfterCurrent] skippingBroken:YES];
}

- (void)addItems:(NSArray *)items
{
    NSUInteger firstNew = [_playlist count];
    [self appendItems:items];
    if (_state == PlayerSessionStopped && firstNew < [_playlist count]) {
        [self playFromIndex:firstNew skippingBroken:YES];
    }
}

- (void)appendItems:(NSArray *)items
{
    for (NSString *item in items) {
        [_playlist addItem:item];
    }
}

- (BOOL)playItemAtIndex:(NSUInteger)index
{
    if (index >= [_playlist count]) {
        return NO;
    }
    if (index == [_playlist currentIndex] && _state != PlayerSessionStopped) {
        return YES;
    }
    return [self playFromIndex:index skippingBroken:NO];
}

#pragma mark - Transport

- (void)togglePlayPause
{
    switch (_state) {
    case PlayerSessionPlaying:
        [_media pause];
        [self setState:PlayerSessionPaused];
        break;
    case PlayerSessionPaused:
        [_media play];
        [self setState:PlayerSessionPlaying];
        break;
    case PlayerSessionStopped:
        if ([_playlist count] > 0) {
            NSUInteger index = [_playlist currentIndex];
            if (index == NSNotFound) {
                index = [_playlist indexAfterCurrent];
            }
            [self playFromIndex:index skippingBroken:YES];
        }
        break;
    }
}

- (void)stop
{
    if (_state == PlayerSessionStopped) {
        return;
    }
    [self closeMedia];
    [self setState:PlayerSessionStopped];
}

- (void)next
{
    NSUInteger index = [_playlist indexAfterCurrent];
    if (index != NSNotFound) {
        [self playFromIndex:index skippingBroken:YES];
    }
}

- (void)previous
{
    if ([_playlist currentIndex] == NSNotFound) {
        return;
    }
    NSUInteger index = [_playlist indexBeforeCurrent];
    if ([self currentTime] > kRestartThreshold || index == NSNotFound) {
        if (_state == PlayerSessionStopped) {
            [self togglePlayPause];
        } else {
            [_media seekToTime:0.0];
        }
        return;
    }
    [self playFromIndex:index skippingBroken:YES];
}

- (void)seekToTime:(NSTimeInterval)seconds
{
    if (![self canSeek]) {
        return;
    }
    [_media seekToTime:MAX(0.0, MIN([self duration], seconds))];
}

- (void)skipBy:(NSTimeInterval)seconds
{
    [self seekToTime:[self currentTime] + seconds];
}

#pragma mark - State

- (NSTimeInterval)currentTime
{
    return (_state == PlayerSessionStopped) ? 0.0 : [_media currentTime];
}

- (NSTimeInterval)duration
{
    return (_state == PlayerSessionStopped) ? 0.0 : [_media duration];
}

- (BOOL)hasVideo
{
    return _state != PlayerSessionStopped && [_media hasVideo];
}

- (BOOL)canPlay
{
    return [_playlist count] > 0;
}

- (BOOL)canStop
{
    return _state != PlayerSessionStopped;
}

- (BOOL)canGoNext
{
    return [_playlist indexAfterCurrent] != NSNotFound && [_playlist currentIndex] != NSNotFound;
}

- (BOOL)canGoPrevious
{
    return [_playlist currentIndex] != NSNotFound;
}

- (BOOL)canSeek
{
    // Live streams have no duration and cannot be sought
    return _state != PlayerSessionStopped && [_media duration] > 0.0;
}

#pragma mark - Internals

- (void)setState:(PlayerSessionState)state
{
    if (state == _state) {
        return;
    }
    _state = state;
    if ([_delegate respondsToSelector:@selector(playerSessionDidChangeState:)]) {
        [_delegate playerSessionDidChangeState:self];
    }
}

- (void)closeMedia
{
    [_media close];
}

// Opens and plays the item at index.  With skippingBroken, items that
// cannot be opened are reported and the following ones tried, as when an
// album plays through.
- (BOOL)playFromIndex:(NSUInteger)index skippingBroken:(BOOL)skipping
{
    NSUInteger attempts = [_playlist count];
    while (index != NSNotFound && attempts-- > 0) {
        NSString *item = [_playlist itemAtIndex:index];
        NSError *error = nil;
        [_playlist setCurrentIndex:index];
        [self notifyTrackChange];

        if ([_media openURL:item error:&error]) {
            [_media setVolume:_volume];
            [_media setMuted:_muted];
            [_media play];
            [self setState:PlayerSessionPlaying];
            return YES;
        }

        if ([_delegate respondsToSelector:@selector(playerSession:didFailToOpenItem:error:)]) {
            [_delegate playerSession:self didFailToOpenItem:item error:error];
        }
        if (!skipping) {
            break;
        }
        index = [_playlist indexAfterCurrent];
    }
    [self setState:PlayerSessionStopped];
    return NO;
}

- (void)notifyTrackChange
{
    if ([_delegate respondsToSelector:@selector(playerSessionDidChangeTrack:)]) {
        [_delegate playerSessionDidChangeTrack:self];
    }
}

#pragma mark - StreamPlayerDelegate

- (void)streamPlayerDidStop:(StreamPlayer *)player
{
    if (_state != PlayerSessionPlaying) {
        return;
    }
    NSUInteger index = [_playlist indexAfterCurrent];
    if (index != NSNotFound && [self playFromIndex:index skippingBroken:YES]) {
        return;
    }
    // The list has played through: ready to play it again from the top
    [self closeMedia];
    [_playlist setCurrentIndex:[_playlist count] > 0 ? 0 : NSNotFound];
    [self notifyTrackChange];
    [self setState:PlayerSessionStopped];
}

- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
    NSString *item = [_playlist currentItem];
    if (item && [_delegate respondsToSelector:@selector(playerSession:didFailToOpenItem:error:)]) {
        [_delegate playerSession:self didFailToOpenItem:item error:error];
    }
}

- (void)streamPlayer:(StreamPlayer *)player didDiscoverVideoWithWidth:(int)width
              height:(int)height
{
    if ([_delegate respondsToSelector:@selector(playerSession:didDiscoverVideoWithWidth:height:)]) {
        [_delegate playerSession:self didDiscoverVideoWithWidth:width height:height];
    }
}

- (void)streamPlayer:(StreamPlayer *)player didDecodeVideoFrameData:(NSData *)rgbaData
              width:(int)width height:(int)height
{
    if ([_delegate respondsToSelector:@selector(playerSession:didDecodeVideoFrameData:width:height:)]) {
        [_delegate playerSession:self didDecodeVideoFrameData:rgbaData width:width height:height];
    }
}

@end
