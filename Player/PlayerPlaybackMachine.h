/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerPlaybackMachine_h
#define PlayerPlaybackMachine_h

#import <Foundation/Foundation.h>
#import "PlayerPlaylist.h"

typedef NS_ENUM(NSInteger, PlayerPlaybackState) {
    PlayerPlaybackEmpty,     // no playlist
    PlayerPlaybackStopped,   // an item is chosen, nothing is open (also: ended)
    PlayerPlaybackOpening,   // the current item is being opened or connected
    PlayerPlaybackPlaying,
    PlayerPlaybackPaused
};

typedef NS_ENUM(NSInteger, PlayerEventType) {
    // Commands
    PlayerEventOpen,           // items: replace the playlist and play it;
                               // flag: the user opened them (Open, a drop)
    PlayerEventAdd,            // items: append; play them if nothing plays;
                               // flag as for Open
    PlayerEventLoad,           // items, index, time: a remembered list, chosen
                               // but not playing (time < 0: from the start)
    PlayerEventSelect,         // index
    PlayerEventPlay,
    PlayerEventPause,
    PlayerEventToggle,
    PlayerEventStop,
    PlayerEventNext,
    PlayerEventPrevious,       // time: how far the current item has played
    PlayerEventSeek,           // time, duration (0: unknown)
    PlayerEventClear,
    // From the media, each tagged with the generation it was opened with
    PlayerEventOpened,
    PlayerEventFailed,         // error
    PlayerEventEnded,
    PlayerEventNearEnd,        // close enough to the end to cross-fade
    PlayerEventDeviceLost,     // error (optional)
    PlayerEventBufferingChanged // flag
};

typedef struct {
    PlayerEventType type;
    NSUInteger generation;
    NSArray *items;
    NSUInteger index;
    NSTimeInterval time;
    NSTimeInterval duration;
    BOOL flag;
    NSError *error;
} PlayerEvent;

PlayerEvent PlayerEventMake(PlayerEventType type);
PlayerEvent PlayerEventWithItems(PlayerEventType type, NSArray *items);
PlayerEvent PlayerEventSelectIndex(NSUInteger index);
PlayerEvent PlayerEventSeekTo(NSTimeInterval time, NSTimeInterval duration);
PlayerEvent PlayerEventPreviousAt(NSTimeInterval position);
PlayerEvent PlayerEventLoadItems(NSArray *items, NSUInteger index, NSTimeInterval time);
PlayerEvent PlayerEventFromMedia(PlayerEventType type, NSUInteger generation);
PlayerEvent PlayerEventFailure(NSUInteger generation, NSError *error);
PlayerEvent PlayerEventBuffering(NSUInteger generation, BOOL buffering);

typedef NS_ENUM(NSInteger, PlayerEffectType) {
    PlayerEffectOpen,          // index, item, generation; flag: cross-fade from
                               // the audible item
    PlayerEffectClose,         // close at once
    PlayerEffectFadeOutClose,  // fade out, then close
    PlayerEffectFadeOutPause,  // fade out, then pause
    PlayerEffectPause,         // pause at once
    PlayerEffectResume,        // play again and fade in
    PlayerEffectSeek,          // time
    PlayerEffectFadeIn,        // the item that just opened, if it is a stream
    PlayerEffectTrackChanged,  // another item became the current one
    PlayerEffectReportFailure  // index, item, error; flag: what the user
                               // opened failed, worth an alert
};

/// One thing the media and the window have to do for a transition.
@interface PlayerEffect : NSObject
{
    PlayerEffectType _type;
    NSUInteger _index;
    NSString *_item;
    NSUInteger _generation;
    NSTimeInterval _time;
    BOOL _flag;
    NSError *_error;
}
@property (nonatomic, readonly) PlayerEffectType type;
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly, copy) NSString *item;
@property (nonatomic, readonly) NSUInteger generation;
@property (nonatomic, readonly) NSTimeInterval time;
@property (nonatomic, readonly) BOOL flag;
@property (nonatomic, readonly, retain) NSError *error;
@end

/// What an event did: the state it left the machine in and the effects to
/// carry out, in order.
@interface PlayerTransition : NSObject
{
    PlayerPlaybackState _fromState;
    PlayerPlaybackState _state;
    NSArray *_effects;
    BOOL _handled;
    BOOL _committed;
}
@property (nonatomic, readonly) PlayerPlaybackState fromState;
@property (nonatomic, readonly) PlayerPlaybackState state;
@property (nonatomic, readonly) NSArray *effects;
/// NO when the event was ignored: not in the table, or of an old generation.
@property (nonatomic, readonly) BOOL handled;
/// A transition was committed (another state, or another item opening):
/// the effects still pending from before are void.
@property (nonatomic, readonly) BOOL committed;
- (BOOL)hasEffect:(PlayerEffectType)type;
- (PlayerEffect *)effectOfType:(PlayerEffectType)type;
@end

/**
 * What playback does, as a table of states and events.  It decides only
 * from its own state and the events it is given - never by asking a media
 * player - and holds no media player: it answers each event with the new
 * state and the effects someone else carries out (PlayerSession).
 * Foundation only, so the whole table is unit tested headless.
 *
 * Main thread only.  Events from the media carry the generation the item
 * was opened with; those of an older generation are dropped.
 */
@interface PlayerPlaybackMachine : NSObject
{
    PlayerPlaybackState _state;
    PlayerPlaylist *_playlist;
    NSUInteger _generation;
    NSUInteger _effectGeneration;
    NSTimeInterval _pendingSeek;
    BOOL _pendingPause;
    BOOL _buffering;
    NSError *_lastError;
    BOOL _skipping;
    NSUInteger _attemptsLeft;
    BOOL _alertOnFailure;      // the user opened what is being tried
    // Collected while an event is handled
    NSMutableArray *_effects;
    BOOL _committed;
}

@property (nonatomic, readonly) PlayerPlaybackState state;
@property (nonatomic, readonly) PlayerPlaylist *playlist;
/// The generation of the item opened last; bumped by every opening and by
/// Stop, so the media's late messages about what it played are dropped.
@property (nonatomic, readonly) NSUInteger generation;
/// Bumped by every committed transition.  Delayed effects (the pause or
/// close after a fade) carry it and are void once it moved on.
@property (nonatomic, readonly) NSUInteger effectGeneration;
/// Where the current item starts once open; < 0: at its beginning.
@property (nonatomic, readonly) NSTimeInterval pendingSeek;
/// Pause was asked for while opening: the item lands paused.
@property (nonatomic, readonly) BOOL pendingPause;
/// The playing stream ran dry and is waiting for data.
@property (nonatomic, readonly) BOOL buffering;
/// The last failure: of the current item, or of the audio output.
@property (nonatomic, readonly, retain) NSError *lastError;

- (PlayerTransition *)handle:(PlayerEvent)event;

/// Describes a state for logs and tests.
+ (NSString *)nameOfState:(PlayerPlaybackState)state;

@end

#endif /* PlayerPlaybackMachine_h */
