/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerSession.h"
#import "PlayerAsync.h"

// Previous restarts the track after this many seconds, like CD players do
static const NSTimeInterval kRestartThreshold = 3.0;
static const NSTimeInterval kDefaultStreamFadeDuration = 1.0;
// Resuming this close to the start of a track counts as starting it, which
// must not soften the attack of its first notes
static const NSTimeInterval kTrackStartTolerance = 0.05;
// How often a playing track is checked for being close enough to its end
// to cross-fade into the next one
static const NSTimeInterval kEndWatchInterval = 0.25;

static BOOL isStream(NSString *item)
{
    return [item rangeOfString:@"://"].location != NSNotFound && ![item hasPrefix:@"file://"];
}

@implementation PlayerSession

@synthesize delegate = _delegate;
@synthesize playlist = _playlist;
@synthesize state = _state;
@synthesize fadeDuration = _fadeDuration;
@synthesize mediaFactory = _mediaFactory;

- (instancetype)initWithMedia:(id<MediaPlayback>)media
{
    self = [super init];
    if (self) {
        _media = [media retain];
        [_media setDelegate:self];
        _playlist = [[PlayerPlaylist alloc] init];
        _volume = 1.0f;
        _state = PlayerSessionStopped;
        _fadeDuration = kDefaultStreamFadeDuration;
        _fadingMedia = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_endWatch invalidate];
    for (id<MediaPlayback> media in _fadingMedia) {
        [media close];
    }
    [_fadingMedia release];
    [_mediaFactory release];
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
        if ([self isConnecting]) {
            // Nothing plays yet that could pause; give up the attempt
            [self stop];
            break;
        }
        if (_fadeDuration > 0 && [_media isPlaying]) {
            // Paused for the user at once, audibly once faded out
            _pausePending = YES;
            [_media fadeToGain:0.0f duration:_fadeDuration];
            [self performSelector:@selector(pauseFadedMedia) withObject:nil
                       afterDelay:_fadeDuration inModes:PlayerRunLoopModes()];
        } else {
            [_media pause];
        }
        [self setState:PlayerSessionPaused];
        break;
    case PlayerSessionPaused:
        [self cancelPendingPause];
        [_media play];
        if (_fadeDuration > 0 && [_media currentTime] > kTrackStartTolerance) {
            [_media fadeToGain:1.0f duration:_fadeDuration];
        } else {
            [_media setFadeGain:1.0f];
        }
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
    BOOL audible = _state == PlayerSessionPlaying || _pausePending;
    if (_fadeDuration > 0 && audible && [_media isPlaying]) {
        // Faded out, then closed; stopped as far as the user is concerned
        [self cancelPendingPause];
        _opening = NO;
        [_media fadeToGain:0.0f duration:_fadeDuration];
        [self performSelector:@selector(closeFadedMedia) withObject:nil
                   afterDelay:_fadeDuration inModes:PlayerRunLoopModes()];
    } else {
        [self closeMedia];
    }
    [self setState:PlayerSessionStopped];
}

- (void)closeFadedMedia
{
    [_media close];
}

- (void)pauseFadedMedia
{
    _pausePending = NO;
    [_media pause];
}

- (void)cancelPendingPause
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(pauseFadedMedia)
                                               object:nil];
    _pausePending = NO;
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

- (BOOL)isConnecting
{
    return _state != PlayerSessionStopped && [_media isConnecting];
}

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
    [self watchTrackEnd:state == PlayerSessionPlaying];
    if ([_delegate respondsToSelector:@selector(playerSessionDidChangeState:)]) {
        [_delegate playerSessionDidChangeState:self];
    }
}

// The timer retains the session, so it runs only while something plays
- (void)watchTrackEnd:(BOOL)watch
{
    if (!watch) {
        [_endWatch invalidate];
        _endWatch = nil;
        return;
    }
    if (_endWatch) {
        return;
    }
    _endWatch = [NSTimer timerWithTimeInterval:kEndWatchInterval target:self
                                      selector:@selector(checkTrackEnd:)
                                      userInfo:nil repeats:YES];
    for (NSString *mode in PlayerRunLoopModes()) {
        [[NSRunLoop currentRunLoop] addTimer:_endWatch forMode:mode];
    }
}

// Starts the next track while the current one is still fading out, so the
// two overlap instead of leaving a gap
- (void)checkTrackEnd:(NSTimer *)timer
{
    NSTimeInterval duration = [_media duration];
    if (_fadeDuration <= 0 || !_mediaFactory || _opening || duration <= 0
        || duration - [_media currentTime] > _fadeDuration) {
        return;
    }
    NSUInteger index = [_playlist indexAfterCurrent];
    if (index != NSNotFound && [_media isPlaying]) {
        [self playFromIndex:index skippingBroken:YES];
    }
}

- (void)closeMedia
{
    // Whatever plays next must not be closed by a fade-out still pending
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(closeFadedMedia)
                                               object:nil];
    [self cancelPendingPause];
    _opening = NO;
    [_media close];
}

// Plays the item at index.  Opening happens in the background; with
// skippingBroken, items that cannot be opened are reported and the
// following ones tried, as when an album plays through.
- (BOOL)playFromIndex:(NSUInteger)index skippingBroken:(BOOL)skipping
{
    if (index == NSNotFound || index >= [_playlist count]) {
        [self setState:PlayerSessionStopped];
        return NO;
    }
    _skipping = skipping;
    _attemptsLeft = [_playlist count];
    [self crossFadeOut];
    [self startItemAtIndex:index];
    return YES;
}

- (void)startItemAtIndex:(NSUInteger)index
{
    _attemptsLeft--;
    [_playlist setCurrentIndex:index];
    [self notifyTrackChange];
    [_media setVolume:_volume];
    [_media setMuted:_muted];
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(closeFadedMedia)
                                               object:nil];
    [self cancelPendingPause];
    // A live stream is joined somewhere in the middle, so it fades in once
    // it plays; a track starts at its beginning, at full volume
    BOOL fadeIn = _fadeDuration > 0 && isStream([_playlist itemAtIndex:index]);
    [_media setFadeGain:fadeIn ? 0.0f : 1.0f];
    // Before -playURL:, which may report back before it returns
    _opening = YES;
    [self setState:PlayerSessionPlaying];
    [_media playURL:[_playlist itemAtIndex:index]];
}

// Lets the audible track fade out in a player of its own while the next
// one plays over it
- (void)crossFadeOut
{
    if (_fadeDuration <= 0 || !_mediaFactory || _state != PlayerSessionPlaying
        || _opening || ![_media isPlaying]) {
        return;
    }
    id<MediaPlayback> outgoing = _media;
    // Its end must not advance the playlist a second time
    [outgoing setDelegate:nil];
    [outgoing fadeToGain:0.0f duration:_fadeDuration];
    [_fadingMedia addObject:outgoing];
    [self performSelector:@selector(closeFadedOut:) withObject:outgoing
               afterDelay:_fadeDuration inModes:PlayerRunLoopModes()];

    _media = [_mediaFactory() retain];
    [_media setDelegate:self];
    [outgoing release];
}

- (void)closeFadedOut:(id<MediaPlayback>)media
{
    [media close];
    [_fadingMedia removeObjectIdenticalTo:media];
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

- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player
{
    _opening = NO;
    if (_fadeDuration > 0 && isStream([_playlist currentItem])) {
        [_media fadeToGain:1.0f duration:_fadeDuration];
    }
    if ([_delegate respondsToSelector:@selector(playerSessionDidChangeState:)]) {
        [_delegate playerSessionDidChangeState:self];
    }
}

- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
    if (_state == PlayerSessionStopped) {
        return;   // e.g. a stream fading out after Stop
    }
    NSString *item = [_playlist currentItem];
    BOOL wasOpening = _opening;
    _opening = NO;
    if (item && [_delegate respondsToSelector:@selector(playerSession:didFailToOpenItem:error:)]) {
        [_delegate playerSession:self didFailToOpenItem:item error:error];
    }
    if (!wasOpening) {
        // It broke off while playing: go on as if it had ended
        _skipping = YES;
        _attemptsLeft = [_playlist count];
    }
    NSUInteger next = _skipping ? [_playlist indexAfterCurrent] : NSNotFound;
    if (next != NSNotFound && _attemptsLeft > 0) {
        [self startItemAtIndex:next];
        return;
    }
    [self closeMedia];
    [self setState:PlayerSessionStopped];
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
