/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerPlaybackMachine.h"

// Previous restarts the item after this many seconds, like CD players do
static const NSTimeInterval kRestartThreshold = 3.0;

PlayerEvent PlayerEventMake(PlayerEventType type)
{
    PlayerEvent event;
    memset(&event, 0, sizeof(event));
    event.type = type;
    event.index = NSNotFound;
    event.time = -1.0;
    return event;
}

PlayerEvent PlayerEventWithItems(PlayerEventType type, NSArray *items)
{
    PlayerEvent event = PlayerEventMake(type);
    event.items = items;
    return event;
}

PlayerEvent PlayerEventSelectIndex(NSUInteger index)
{
    PlayerEvent event = PlayerEventMake(PlayerEventSelect);
    event.index = index;
    return event;
}

PlayerEvent PlayerEventSeekTo(NSTimeInterval time, NSTimeInterval duration)
{
    PlayerEvent event = PlayerEventMake(PlayerEventSeek);
    event.time = time;
    event.duration = duration;
    return event;
}

PlayerEvent PlayerEventPreviousAt(NSTimeInterval position)
{
    PlayerEvent event = PlayerEventMake(PlayerEventPrevious);
    event.time = position;
    return event;
}

PlayerEvent PlayerEventLoadItems(NSArray *items, NSUInteger index, NSTimeInterval time)
{
    PlayerEvent event = PlayerEventWithItems(PlayerEventLoad, items);
    event.index = index;
    event.time = time;
    return event;
}

PlayerEvent PlayerEventFromMedia(PlayerEventType type, NSUInteger generation)
{
    PlayerEvent event = PlayerEventMake(type);
    event.generation = generation;
    return event;
}

PlayerEvent PlayerEventFailure(NSUInteger generation, NSError *error)
{
    PlayerEvent event = PlayerEventFromMedia(PlayerEventFailed, generation);
    event.error = error;
    return event;
}

PlayerEvent PlayerEventBuffering(NSUInteger generation, BOOL buffering)
{
    PlayerEvent event = PlayerEventFromMedia(PlayerEventBufferingChanged, generation);
    event.flag = buffering;
    return event;
}

static BOOL isMediaEvent(PlayerEventType type)
{
    return type >= PlayerEventOpened;
}

#pragma mark - PlayerEffect

@implementation PlayerEffect

@synthesize type = _type;
@synthesize index = _index;
@synthesize item = _item;
@synthesize generation = _generation;
@synthesize time = _time;
@synthesize flag = _flag;
@synthesize error = _error;

- (instancetype)initWithType:(PlayerEffectType)type index:(NSUInteger)index
                        item:(NSString *)item generation:(NSUInteger)generation
                        time:(NSTimeInterval)time flag:(BOOL)flag error:(NSError *)error
{
    self = [super init];
    if (self) {
        _type = type;
        _index = index;
        _item = [item copy];
        _generation = generation;
        _time = time;
        _flag = flag;
        _error = [error retain];
    }
    return self;
}

+ (instancetype)effectOfType:(PlayerEffectType)type
{
    return [[[self alloc] initWithType:type index:NSNotFound item:nil generation:0
                                  time:0 flag:NO error:nil] autorelease];
}

- (void)dealloc
{
    [_item release];
    [_error release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<PlayerEffect %ld index %lu gen %lu time %.2f flag %d>",
            (long)_type, (unsigned long)_index, (unsigned long)_generation, _time, _flag];
}

@end

#pragma mark - PlayerTransition

@implementation PlayerTransition

@synthesize fromState = _fromState;
@synthesize state = _state;
@synthesize effects = _effects;
@synthesize handled = _handled;
@synthesize committed = _committed;

- (instancetype)initFrom:(PlayerPlaybackState)from to:(PlayerPlaybackState)to
                 effects:(NSArray *)effects handled:(BOOL)handled committed:(BOOL)committed
{
    self = [super init];
    if (self) {
        _fromState = from;
        _state = to;
        _effects = [effects copy];
        _handled = handled;
        _committed = committed;
    }
    return self;
}

- (void)dealloc
{
    [_effects release];
    [super dealloc];
}

- (PlayerEffect *)effectOfType:(PlayerEffectType)type
{
    for (PlayerEffect *effect in _effects) {
        if ([effect type] == type) {
            return effect;
        }
    }
    return nil;
}

- (BOOL)hasEffect:(PlayerEffectType)type
{
    return [self effectOfType:type] != nil;
}

@end

#pragma mark - PlayerPlaybackMachine

@implementation PlayerPlaybackMachine

@synthesize state = _state;
@synthesize playlist = _playlist;
@synthesize generation = _generation;
@synthesize effectGeneration = _effectGeneration;
@synthesize pendingSeek = _pendingSeek;
@synthesize pendingPause = _pendingPause;
@synthesize buffering = _buffering;
@synthesize lastError = _lastError;

+ (NSString *)nameOfState:(PlayerPlaybackState)state
{
    switch (state) {
    case PlayerPlaybackEmpty: return @"Empty";
    case PlayerPlaybackStopped: return @"Stopped";
    case PlayerPlaybackOpening: return @"Opening";
    case PlayerPlaybackPlaying: return @"Playing";
    case PlayerPlaybackPaused: return @"Paused";
    }
    return @"?";
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _state = PlayerPlaybackEmpty;
        _playlist = [[PlayerPlaylist alloc] init];
        _pendingSeek = -1.0;
    }
    return self;
}

- (void)dealloc
{
    [_playlist release];
    [_lastError release];
    [_effects release];
    [super dealloc];
}

- (void)setLastError:(NSError *)error
{
    if (error != _lastError) {
        [_lastError release];
        _lastError = [error retain];
    }
}

#pragma mark - Handling

- (PlayerTransition *)handle:(PlayerEvent)event
{
    PlayerPlaybackState from = _state;
    [_effects release];
    _effects = [[NSMutableArray alloc] init];
    _committed = NO;

    BOOL handled;
    if (isMediaEvent(event.type) && event.generation != _generation) {
        // About an item given up since; whatever it says changes nothing
        NSDebugLLog(@"PlayerPlaybackMachine", @"dropped event %ld of generation %lu (now %lu)",
                    (long)event.type, (unsigned long)event.generation,
                    (unsigned long)_generation);
        handled = NO;
    } else {
        switch (_state) {
        case PlayerPlaybackEmpty:   handled = [self handleInEmpty:event]; break;
        case PlayerPlaybackStopped: handled = [self handleInStopped:event]; break;
        case PlayerPlaybackOpening: handled = [self handleInOpening:event]; break;
        case PlayerPlaybackPlaying: handled = [self handleInPlaying:event]; break;
        case PlayerPlaybackPaused:  handled = [self handleInPaused:event]; break;
        default: handled = NO; break;
        }
        if (!handled) {
            NSDebugLLog(@"PlayerPlaybackMachine", @"ignored event %ld in state %@",
                        (long)event.type, [[self class] nameOfState:_state]);
        }
    }
    if (_state != from) {
        _committed = YES;
    }
    if (_committed) {
        // The one place the old state's pending effects are cancelled
        _effectGeneration++;
    }
    PlayerTransition *transition = [[PlayerTransition alloc] initFrom:from to:_state
                                                              effects:_effects
                                                              handled:handled
                                                            committed:_committed];
    [_effects release];
    _effects = nil;
    return [transition autorelease];
}

#pragma mark - Per state

- (BOOL)handleInEmpty:(PlayerEvent)event
{
    switch (event.type) {
    case PlayerEventOpen:
    case PlayerEventAdd:
        return [self openItems:event.items replacing:event.type == PlayerEventOpen];
    case PlayerEventLoad:
        return [self loadEvent:event];
    default:
        return NO;
    }
}

- (BOOL)handleInStopped:(PlayerEvent)event
{
    switch (event.type) {
    case PlayerEventOpen:
    case PlayerEventAdd:
        return [self openItems:event.items replacing:event.type == PlayerEventOpen];
    case PlayerEventPlay:
    case PlayerEventToggle: {
        NSUInteger index = [_playlist currentIndex];
        if (index == NSNotFound) {
            index = [_playlist indexAfterCurrent];
        }
        return [self startFrom:index skipping:YES crossFade:NO];
    }
    case PlayerEventSelect:
        return [self startFrom:event.index skipping:NO crossFade:NO];
    case PlayerEventNext:
        return [self startFrom:[_playlist indexAfterCurrent] skipping:YES crossFade:NO];
    case PlayerEventPrevious:
        return [self previous:event crossFade:NO];
    case PlayerEventSeek:
        // Nothing is open to move: the item starts there when played
        _pendingSeek = MAX(0.0, event.time);
        return YES;
    case PlayerEventClear:
        [_playlist removeAllItems];
        _pendingSeek = -1.0;
        [self setLastError:nil];
        _state = PlayerPlaybackEmpty;
        [self addEffect:PlayerEffectTrackChanged];
        return YES;
    default:
        return NO;
    }
}

- (BOOL)handleInOpening:(PlayerEvent)event
{
    switch (event.type) {
    case PlayerEventOpened:
        [self setLastError:nil];
        if (_pendingSeek >= 0) {
            [self addEffect:PlayerEffectSeek time:_pendingSeek];
            _pendingSeek = -1.0;
        }
        if (_pendingPause) {
            _pendingPause = NO;
            [self addEffect:PlayerEffectPause];
            _state = PlayerPlaybackPaused;
        } else {
            [self addEffect:PlayerEffectFadeIn];
            _state = PlayerPlaybackPlaying;
        }
        return YES;
    case PlayerEventFailed:
        [self report:event.error];
        if (_skipping && _attemptsLeft > 0) {
            NSUInteger next = [_playlist indexAfterCurrent];
            if (next != NSNotFound) {
                [self openIndex:next crossFade:NO];
                return YES;
            }
        }
        [self stopWith:PlayerEffectClose];
        return YES;
    case PlayerEventSeek:
        _pendingSeek = MAX(0.0, event.time);
        return YES;
    case PlayerEventPause:
        _pendingPause = YES;
        return YES;
    case PlayerEventPlay:
        _pendingPause = NO;
        return YES;
    case PlayerEventToggle:
        _pendingPause = !_pendingPause;
        return YES;
    case PlayerEventStop:
        [self stopWith:PlayerEffectClose];
        return YES;
    case PlayerEventOpen:
        return [self openItems:event.items replacing:YES];
    case PlayerEventAdd:
        return [self appendItems:event.items] != NSNotFound;
    case PlayerEventSelect:
        if (event.index == [_playlist currentIndex]) {
            return NO;   // that one is opening already
        }
        [self dropPending];
        return [self startFrom:event.index skipping:NO crossFade:NO];
    case PlayerEventNext: {
        NSUInteger next = [_playlist indexAfterCurrent];
        if (next == NSNotFound) {
            return NO;
        }
        [self dropPending];
        return [self startFrom:next skipping:YES crossFade:NO];
    }
    case PlayerEventPrevious:
        [self dropPending];
        return [self previous:event crossFade:NO];
    case PlayerEventDeviceLost:
        [self loseDevice:event];
        return YES;
    default:
        return NO;
    }
}

- (BOOL)handleInPlaying:(PlayerEvent)event
{
    switch (event.type) {
    case PlayerEventPause:
    case PlayerEventToggle:
        [self addEffect:PlayerEffectFadeOutPause];
        _state = PlayerPlaybackPaused;
        return YES;
    case PlayerEventSeek:
        return [self seek:event];
    case PlayerEventStop:
        [self stopWith:PlayerEffectFadeOutClose];
        return YES;
    case PlayerEventEnded:
        return [self advanceAfterEnd];
    case PlayerEventNearEnd: {
        NSUInteger next = [_playlist indexAfterCurrent];
        if (next == NSNotFound) {
            return NO;   // the last item plays out to its end
        }
        return [self startFrom:next skipping:YES crossFade:YES];
    }
    case PlayerEventFailed:
        // It broke off while playing: go on as if it had ended
        [self report:event.error];
        if ([_playlist indexAfterCurrent] != NSNotFound) {
            return [self startFrom:[_playlist indexAfterCurrent] skipping:YES crossFade:NO];
        }
        [self stopWith:PlayerEffectClose];
        return YES;
    case PlayerEventDeviceLost:
        [self loseDevice:event];
        return YES;
    case PlayerEventBufferingChanged:
        _buffering = event.flag;
        return YES;
    default:
        return [self handleChoiceOf:event crossFade:YES];
    }
}

- (BOOL)handleInPaused:(PlayerEvent)event
{
    switch (event.type) {
    case PlayerEventPlay:
    case PlayerEventToggle:
        [self setLastError:nil];
        [self addEffect:PlayerEffectResume];
        _state = PlayerPlaybackPlaying;
        return YES;
    case PlayerEventSeek:
        return [self seek:event];
    case PlayerEventStop:
        [self stopWith:PlayerEffectFadeOutClose];
        return YES;
    case PlayerEventEnded: {
        // The end came in after the pause: ready on the next item, without
        // playing it behind the user's back
        NSUInteger next = [_playlist indexAfterCurrent];
        [self stopWith:PlayerEffectClose];
        [self chooseIndex:next != NSNotFound ? next : 0];
        return YES;
    }
    case PlayerEventDeviceLost:
        [self loseDevice:event];
        return YES;
    case PlayerEventBufferingChanged:
        _buffering = event.flag;
        return YES;
    default:
        // Nothing is audible that could cross-fade
        return [self handleChoiceOf:event crossFade:NO];
    }
}

// Choosing another item while something is open
- (BOOL)handleChoiceOf:(PlayerEvent)event crossFade:(BOOL)crossFade
{
    switch (event.type) {
    case PlayerEventOpen:
        return [self openItems:event.items replacing:YES];
    case PlayerEventAdd:
        return [self appendItems:event.items] != NSNotFound;
    case PlayerEventSelect:
        if (event.index == [_playlist currentIndex]) {
            return NO;   // that one plays already
        }
        return [self startFrom:event.index skipping:NO crossFade:crossFade];
    case PlayerEventNext:
        return [self startFrom:[_playlist indexAfterCurrent] skipping:YES crossFade:crossFade];
    case PlayerEventPrevious:
        return [self previous:event crossFade:crossFade];
    default:
        return NO;
    }
}

#pragma mark - Transitions

- (void)addEffect:(PlayerEffectType)type
{
    [self addEffectObject:[PlayerEffect effectOfType:type]];
}

- (void)addEffect:(PlayerEffectType)type time:(NSTimeInterval)time
{
    [self addEffectObject:[[[PlayerEffect alloc] initWithType:type index:NSNotFound item:nil
                                                   generation:0 time:time flag:NO
                                                        error:nil] autorelease]];
}

- (void)addEffectObject:(PlayerEffect *)effect
{
    [_effects addObject:effect];
}

- (void)dropPending
{
    _pendingSeek = -1.0;
    _pendingPause = NO;
}

// Appends what is not in the list yet; returns the index of the first new
// item, NSNotFound if nothing was added
- (NSUInteger)appendItems:(NSArray *)items
{
    NSUInteger firstNew = [_playlist count];
    for (NSString *item in items) {
        [_playlist addItem:item];
    }
    return firstNew < [_playlist count] ? firstNew : NSNotFound;
}

- (BOOL)openItems:(NSArray *)items replacing:(BOOL)replacing
{
    if (replacing) {
        if ([items count] == 0) {
            return NO;
        }
        [self dropPending];
        [self setLastError:nil];
        [_playlist removeAllItems];
        [self appendItems:items];
        return [self startFrom:[_playlist indexAfterCurrent] skipping:YES crossFade:NO];
    }
    NSUInteger firstNew = [self appendItems:items];
    if (firstNew == NSNotFound) {
        return NO;
    }
    return [self startFrom:firstNew skipping:YES crossFade:NO];
}

- (BOOL)loadEvent:(PlayerEvent)event
{
    [self appendItems:event.items];
    if ([_playlist count] == 0) {
        return NO;
    }
    _state = PlayerPlaybackStopped;
    if (event.index < [_playlist count]) {
        [self chooseIndex:event.index];
        if (event.time > 0) {
            _pendingSeek = event.time;
        }
    }
    return YES;
}

// A user's choice (or the list moving on) starts a fresh run of attempts:
// with skipping, items that cannot be opened are passed over, as when an
// album plays through, but only once around the list
- (BOOL)startFrom:(NSUInteger)index skipping:(BOOL)skipping crossFade:(BOOL)crossFade
{
    if (index == NSNotFound || index >= [_playlist count]) {
        return NO;
    }
    _skipping = skipping;
    _attemptsLeft = [_playlist count];
    [self setLastError:nil];
    [self openIndex:index crossFade:crossFade];
    return YES;
}

- (void)openIndex:(NSUInteger)index crossFade:(BOOL)crossFade
{
    if (index != [_playlist currentIndex]) {
        // A position asked for belongs to the item it was asked for on
        _pendingSeek = -1.0;
    }
    if (_attemptsLeft > 0) {
        _attemptsLeft--;
    }
    _generation++;
    _buffering = NO;
    _state = PlayerPlaybackOpening;
    _committed = YES;
    [_playlist setCurrentIndex:index];
    [self addEffect:PlayerEffectTrackChanged];

    [self addEffectObject:[[[PlayerEffect alloc] initWithType:PlayerEffectOpen index:index
                                                         item:[_playlist itemAtIndex:index]
                                                   generation:_generation time:0
                                                         flag:crossFade error:nil] autorelease]];
}

- (void)chooseIndex:(NSUInteger)index
{
    if (index != [_playlist currentIndex]) {
        [_playlist setCurrentIndex:index];
        [self addEffect:PlayerEffectTrackChanged];
    }
}

// Whatever the media says about what it played from now on is old news
- (void)stopWith:(PlayerEffectType)closing
{
    [self dropPending];
    _buffering = NO;
    _generation++;
    [self addEffect:closing];
    _state = PlayerPlaybackStopped;
}

- (BOOL)previous:(PlayerEvent)event crossFade:(BOOL)crossFade
{
    NSUInteger current = [_playlist currentIndex];
    if (current == NSNotFound) {
        return NO;
    }
    NSUInteger before = [_playlist indexBeforeCurrent];
    if (event.time > kRestartThreshold || before == NSNotFound) {
        if (_state == PlayerPlaybackPlaying || _state == PlayerPlaybackPaused) {
            // Back to the start of the item that is open
            [self addEffect:PlayerEffectSeek time:0.0];
            return YES;
        }
        return [self startFrom:current skipping:YES crossFade:NO];
    }
    return [self startFrom:before skipping:YES crossFade:crossFade];
}

- (BOOL)seek:(PlayerEvent)event
{
    // A live stream has no length and cannot be sought
    if (event.duration <= 0) {
        return NO;
    }
    [self addEffect:PlayerEffectSeek time:MAX(0.0, MIN(event.duration, event.time))];
    return YES;
}

- (BOOL)advanceAfterEnd
{
    NSUInteger next = [_playlist indexAfterCurrent];
    if (next != NSNotFound) {
        return [self startFrom:next skipping:YES crossFade:NO];
    }
    // The list has played through: ready to play it again from the top
    [self stopWith:PlayerEffectClose];
    [self chooseIndex:0];
    return YES;
}

- (void)report:(NSError *)error
{
    [self setLastError:error];
    [self addEffectObject:[[[PlayerEffect alloc] initWithType:PlayerEffectReportFailure
                                                        index:[_playlist currentIndex]
                                                         item:[_playlist currentItem]
                                                   generation:_generation time:0 flag:NO
                                                        error:error] autorelease]];
}

- (void)loseDevice:(PlayerEvent)event
{
    NSError *error = event.error;
    if (!error) {
        error = [NSError errorWithDomain:@"Player" code:1 userInfo:
            @{NSLocalizedDescriptionKey: @"Audio output is not available"}];
    }
    [self setLastError:error];
    _buffering = NO;
    if (_state != PlayerPlaybackPaused) {
        [self addEffect:PlayerEffectPause];
        _state = PlayerPlaybackPaused;
    }
}

@end
