/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerSession.h"
#import "PlayerAsync.h"

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

/// The pause or close that waits for a fade-out.  It belongs to the state
/// that asked for it and is void once the machine committed another
/// transition (its effect generation moved on).
@interface PlayerDelayedEffect : NSObject
{
@public
    PlayerEffectType type;
    NSUInteger effectGeneration;
    id<MediaPlayback> media;
}
@end

@implementation PlayerDelayedEffect
- (void)dealloc
{
    [media release];
    [super dealloc];
}
@end

@implementation PlayerSession

@synthesize delegate = _delegate;
@synthesize fadeDuration = _fadeDuration;
@synthesize mediaFactory = _mediaFactory;

- (instancetype)initWithMedia:(id<MediaPlayback>)media
{
    self = [super init];
    if (self) {
        _media = [media retain];
        [_media setDelegate:self];
        _machine = [[PlayerPlaybackMachine alloc] init];
        _volume = 1.0f;
        _fadeDuration = kDefaultStreamFadeDuration;
        _fadingMedia = [[NSMutableArray alloc] init];
        _queuedEvents = [[NSMutableArray alloc] init];
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
    [_queuedEvents release];
    [_mediaFactory release];
    [_media setDelegate:nil];
    [_media close];
    [_media release];
    [_machine release];
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

#pragma mark - Commands

- (void)openItems:(NSArray *)items
{
    [self send:PlayerEventWithItems(PlayerEventOpen, items)];
}

- (void)addItems:(NSArray *)items
{
    [self send:PlayerEventWithItems(PlayerEventAdd, items)];
}

- (BOOL)playItemAtIndex:(NSUInteger)index
{
    if (index >= [[self playlist] count]) {
        return NO;
    }
    [self send:PlayerEventSelectIndex(index)];
    return YES;
}

- (void)togglePlayPause
{
    [self send:PlayerEventMake(PlayerEventToggle)];
}

- (void)stop
{
    [self send:PlayerEventMake(PlayerEventStop)];
}

- (void)next
{
    [self send:PlayerEventMake(PlayerEventNext)];
}

- (void)previous
{
    [self send:PlayerEventPreviousAt([self currentTime])];
}

- (void)seekToTime:(NSTimeInterval)seconds
{
    [self send:PlayerEventSeekTo(seconds, [self duration])];
}

- (void)skipBy:(NSTimeInterval)seconds
{
    [self seekToTime:[self currentTime] + seconds];
}

#pragma mark - Remembering

static NSString *const kStatePlaying = @"playing";
static NSString *const kStatePaused = @"paused";
static NSString *const kStateStopped = @"stopped";

- (NSDictionary *)stateToRemember
{
    PlayerPlaylist *playlist = [self playlist];
    NSUInteger index = [playlist currentIndex];
    PlayerPlaybackState state = [_machine state];
    // An item still opening was about to play, or to be paused
    BOOL opening = state == PlayerPlaybackOpening;
    BOOL playing = state == PlayerPlaybackPlaying || (opening && ![_machine pendingPause]);
    BOOL paused = state == PlayerPlaybackPaused || (opening && [_machine pendingPause]);
    NSString *name = playing ? kStatePlaying : paused ? kStatePaused : kStateStopped;
    NSTimeInterval position = [_machine pendingSeek] >= 0 ? [_machine pendingSeek]
                                                          : [self currentTime];
    return @{@"items": [[[playlist items] copy] autorelease],
             @"currentIndex": @(index == NSNotFound ? -1 : (NSInteger)index),
             @"position": @(position),
             @"state": name};
}

- (void)restoreState:(NSDictionary *)state
{
    NSArray *items = [state isKindOfClass:[NSDictionary class]] ? [state objectForKey:@"items"] : nil;
    if (![items isKindOfClass:[NSArray class]]) {
        return;
    }
    for (id item in items) {
        if (![item isKindOfClass:[NSString class]]) {
            return;
        }
    }
    id indexValue = [state objectForKey:@"currentIndex"];
    id positionValue = [state objectForKey:@"position"];
    NSInteger index = [indexValue respondsToSelector:@selector(integerValue)] ? [indexValue integerValue] : -1;
    NSTimeInterval position = [positionValue respondsToSelector:@selector(doubleValue)]
        ? [positionValue doubleValue] : 0.0;
    NSString *playState = [state objectForKey:@"state"];
    BOOL playing = [kStatePlaying isEqual:playState];
    // Only a track that played or was paused continues where it was
    BOOL resumes = playing || [kStatePaused isEqual:playState];

    [self send:PlayerEventMake(PlayerEventStop)];
    [self send:PlayerEventMake(PlayerEventClear)];
    [self send:PlayerEventLoadItems(items, index < 0 ? NSNotFound : (NSUInteger)index,
                                    resumes ? position : -1.0)];
    if (playing && index >= 0) {
        [self send:PlayerEventMake(PlayerEventPlay)];
    }
}

#pragma mark - State

- (PlayerPlaylist *)playlist
{
    return [_machine playlist];
}

- (PlayerPlaybackState)state
{
    return [_machine state];
}

- (NSError *)lastError
{
    return [_machine lastError];
}

- (BOOL)isBuffering
{
    return [_machine buffering];
}

- (BOOL)isConnecting
{
    return [_machine state] == PlayerPlaybackOpening;
}

- (BOOL)isPausePending
{
    return [_machine state] == PlayerPlaybackOpening && [_machine pendingPause];
}

// Something is open: a position, a length and pictures exist only then
- (BOOL)hasOpenMedia
{
    PlayerPlaybackState state = [_machine state];
    return state == PlayerPlaybackPlaying || state == PlayerPlaybackPaused;
}

- (NSTimeInterval)currentTime
{
    return [self hasOpenMedia] ? [_media currentTime] : 0.0;
}

- (NSTimeInterval)duration
{
    return [self hasOpenMedia] ? [_media duration] : 0.0;
}

- (BOOL)hasVideo
{
    return [self hasOpenMedia] && [_media hasVideo];
}

- (BOOL)canPlay
{
    return [[self playlist] count] > 0;
}

- (BOOL)canStop
{
    PlayerPlaybackState state = [_machine state];
    return state != PlayerPlaybackStopped && state != PlayerPlaybackEmpty;
}

- (BOOL)canGoNext
{
    PlayerPlaylist *playlist = [self playlist];
    return [playlist indexAfterCurrent] != NSNotFound && [playlist currentIndex] != NSNotFound;
}

- (BOOL)canGoPrevious
{
    return [[self playlist] currentIndex] != NSNotFound;
}

- (BOOL)canSeek
{
    // Live streams have no duration and cannot be sought
    return [self hasOpenMedia] && [_media duration] > 0.0;
}

#pragma mark - Events and effects

// Only the main thread transitions.  The machine commits a transition
// before any of its effects run; an effect that calls back into the
// session (a media player reporting before -playURL: returns) queues its
// event until the effects of this one are done, so no transition starts in
// the middle of another.
- (void)send:(PlayerEvent)event
{
    if (_handling) {
        // The value holds the pointers; the objects are kept until handled
        [event.items retain];
        [event.error retain];
        [_queuedEvents addObject:[NSValue valueWithBytes:&event objCType:@encode(PlayerEvent)]];
        return;
    }
    _handling = YES;
    [self handle:event];
    while ([_queuedEvents count] > 0) {
        PlayerEvent queued;
        [[_queuedEvents objectAtIndex:0] getValue:&queued];
        [_queuedEvents removeObjectAtIndex:0];
        [self handle:queued];
        [queued.items release];
        [queued.error release];
    }
    _handling = NO;
}

- (void)handle:(PlayerEvent)event
{
    PlayerTransition *transition = [_machine handle:event];
    if (![transition handled]) {
        return;
    }
    if ([transition committed]) {
        [self watchTrackEnd:[transition state] == PlayerPlaybackPlaying];
    }
    for (PlayerEffect *effect in [transition effects]) {
        [self perform:effect];
    }
    if ([_delegate respondsToSelector:@selector(playerSessionDidChangeState:)]) {
        [_delegate playerSessionDidChangeState:self];
    }
}

- (void)perform:(PlayerEffect *)effect
{
    switch ([effect type]) {
    case PlayerEffectOpen:
        [self openItem:[effect item] generation:[effect generation] crossFade:[effect flag]];
        break;
    case PlayerEffectClose:
        [_media close];
        break;
    case PlayerEffectFadeOutClose:
    case PlayerEffectFadeOutPause:
        [self fadeOutThen:[effect type]];
        break;
    case PlayerEffectPause:
        [_media pause];
        break;
    case PlayerEffectResume:
        [_media play];
        if (_fadeDuration > 0 && [_media currentTime] > kTrackStartTolerance) {
            [_media fadeToGain:1.0f duration:_fadeDuration];
        } else {
            [_media setFadeGain:1.0f];
        }
        break;
    case PlayerEffectSeek:
        [_media seekToTime:[effect time]];
        break;
    case PlayerEffectFadeIn:
        if (_fadeDuration > 0 && isStream([[self playlist] currentItem])) {
            [_media fadeToGain:1.0f duration:_fadeDuration];
        }
        break;
    case PlayerEffectTrackChanged:
        if ([_delegate respondsToSelector:@selector(playerSessionDidChangeTrack:)]) {
            [_delegate playerSessionDidChangeTrack:self];
        }
        break;
    case PlayerEffectReportFailure:
        if ([effect item]
            && [_delegate respondsToSelector:@selector(playerSession:didFailToOpenItem:error:)]) {
            [_delegate playerSession:self didFailToOpenItem:[effect item] error:[effect error]];
        }
        break;
    }
}

- (void)openItem:(NSString *)item generation:(NSUInteger)generation crossFade:(BOOL)crossFade
{
    if (crossFade) {
        [self crossFadeOut];
    }
    _mediaGeneration = generation;
    [_media setVolume:_volume];
    [_media setMuted:_muted];
    // A live stream is joined somewhere in the middle, so it fades in once
    // it plays; a track starts at its beginning, at full volume
    BOOL fadeIn = _fadeDuration > 0 && isStream(item);
    [_media setFadeGain:fadeIn ? 0.0f : 1.0f];
    [_media playURL:item];
}

// The state changes at once; the sound fades out first and the media
// pauses or closes afterwards, unless another transition came in between
- (void)fadeOutThen:(PlayerEffectType)type
{
    BOOL audible = [_media fadeGain] > 0.0f;
    if (_fadeDuration <= 0 || !audible) {
        [self finishFadeOut:type];
        return;
    }
    [_media fadeToGain:0.0f duration:_fadeDuration];
    PlayerDelayedEffect *delayed = [[[PlayerDelayedEffect alloc] init] autorelease];
    delayed->type = type;
    delayed->effectGeneration = [_machine effectGeneration];
    delayed->media = [_media retain];
    [self performSelector:@selector(performDelayedEffect:) withObject:delayed
               afterDelay:_fadeDuration inModes:PlayerRunLoopModes()];
}

- (void)performDelayedEffect:(PlayerDelayedEffect *)delayed
{
    if (delayed->effectGeneration != [_machine effectGeneration] || delayed->media != _media) {
        return;
    }
    [self finishFadeOut:delayed->type];
}

- (void)finishFadeOut:(PlayerEffectType)type
{
    if (type == PlayerEffectFadeOutPause) {
        [_media pause];
    } else {
        [_media close];
    }
}

// Lets the audible track fade out in a player of its own while the next
// one plays over it
- (void)crossFadeOut
{
    if (_fadeDuration <= 0 || !_mediaFactory) {
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
    if (_fadeDuration <= 0 || !_mediaFactory || duration <= 0
        || duration - [_media currentTime] > _fadeDuration) {
        return;
    }
    [self send:PlayerEventFromMedia(PlayerEventNearEnd, _mediaGeneration)];
}

#pragma mark - StreamPlayerDelegate

- (void)streamPlayerDidStop:(StreamPlayer *)player
{
    [self send:PlayerEventFromMedia(PlayerEventEnded, _mediaGeneration)];
}

- (void)streamPlayerDidStartPlaying:(StreamPlayer *)player
{
    [self send:PlayerEventFromMedia(PlayerEventOpened, _mediaGeneration)];
}

- (void)streamPlayer:(StreamPlayer *)player didFailWithError:(NSError *)error
{
    [self send:PlayerEventFailure(_mediaGeneration, error)];
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
