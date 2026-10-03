/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MediaExtra.h"

#import "GSMediaPlayer2.h"
#import "GSMenuExtraContext.h"
#import "MediaHub.h"

/* The size a menu item draws its icon at.  The icons themselves are on the
   menu bar's 18px grid, so a menu item - which has less height to spend -
   takes them a little smaller. */
static const CGFloat kItemIconSize = 16.0;

@implementation MediaExtra
{
    BOOL _running;
    GSMenuExtraContext *_context;
    MediaHub *_hub;
    /* What the menu bar was last told, so that a poll that finds nothing
       new does not redraw the bar. */
    NSString *_shownState;
    /* What the button was just told to expect, until the player says what
       it did.  See -image and -expectTheState:. */
    NSString *_expectedStatus;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

#pragma mark - GSMenuExtra

/* A media key presses play/pause on whatever the user is listening to, so
   this extra belongs in the menu bar from the first time it is installed
   rather than waiting to be found in the preferences.  The manager puts this
   extra's identifier into the saved GSMenuExtraEnabled set the first time
   it sees this answer YES, and writes the user's own set back. */
- (BOOL)enabledByDefault
{
    return YES;
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        _hub = [MediaHub sharedHub];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(mediaChanged:)
                                                     name:MediaHubChangedNotification
                                                   object:nil];
        _shownState = nil;
        [self redrawIfChanged];
    } @catch (NSException *e) {
        NSLog(@"MediaExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
    }
}

- (void)menuExtraWillUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _shownState = nil;
}

/* The menu bar item is a readout of what the player is doing, not a button
   that says what pressing it would do: a playing player wears the play
   symbol, a paused one the pause symbol, and a stopped one the stop symbol.

   The two readings are opposites - a button would show pause while playing,
   because that is what the press would do - and the difference matters to
   anyone glancing at the bar without clicking it.  The click still toggles:
   the menu below carries the commands, and the item here is for reading.

   A player that has just been told to change is shown as changed before it
   says so, because a readout that lags a moment behind looks broken; what
   the player reports a moment later replaces it either way.  No player, no
   icon, and so nothing at all in the menu bar. */
- (NSImage *)image
{
    MediaPlayerEntry *player = [_hub currentPlayer];
    if (player == nil) return nil;

    NSString *status = _expectedStatus ?: player.playbackStatus;
    if ([status isEqualToString:GSMediaPlayer2Playing]) {
        return [NSImage imageNamed:@"media-play"];
    }
    if ([status isEqualToString:GSMediaPlayer2Stopped]) {
        return [NSImage imageNamed:@"media-stop"];
    }
    return [NSImage imageNamed:@"media-pause"];
}

/* An icon and nothing else, as the other extras that are not a number. */
- (NSString *)title
{
    return @"";
}

- (void)tick
{
    if (!_running) return;
    @try {
        /* Whatever the button was shown on the strength of a command the
           player never confirmed is given up here, so the bar cannot claim
           a state the player is not in for longer than one poll. */
        _expectedStatus = nil;
        [self redrawIfChanged];
    } @catch (NSException *e) {
        NSLog(@"MediaExtra: exception in tick: %@", e);
    }
}

- (void)mediaChanged:(NSNotification *)notification
{
    (void)notification;
    if (!_running) return;
    @try {
        MediaPlayerEntry *player = [_hub currentPlayer];
        if (_expectedStatus != nil &&
            [_expectedStatus isEqualToString:player.playbackStatus]) {
            /* The player did what the button said it would, so the state
               the bar was shown on its behalf is now the state it reported.
               Anything else is left to the tick above: a player that changed
               something else has not yet answered the command. */
            _expectedStatus = nil;
        }
        [self redrawIfChanged];
    } @catch (NSException *e) {
        NSLog(@"MediaExtra: exception on the media notification: %@", e);
    }
}

#pragma mark - The menu

- (NSMenu *)menu
{
    NSArray<MediaPlayerEntry *> *players = [_hub knownPlayers];
    MediaPlayerEntry *current = [_hub currentPlayer];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Media"];

    if ([players count] == 0) {
        /* Reachable by the keyboard, and by a click on a menu bar item that
           was there a moment ago: the player may have quit since. */
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"No Media Player Running"
                                                      action:NULL
                                               keyEquivalent:@""];
        [none setEnabled:NO];
        [menu addItem:none];
        return menu;
    }

    NSString *playing = [self nowPlayingForEntry:current];
    if (playing != nil) {
        NSMenuItem *nowPlaying = [[NSMenuItem alloc] initWithTitle:playing
                                                            action:NULL
                                                     keyEquivalent:@""];
        [nowPlaying setEnabled:NO];
        [menu addItem:nowPlaying];
    } else {
        NSMenuItem *identity = [[NSMenuItem alloc] initWithTitle:current.identity
                                                          action:NULL
                                                   keyEquivalent:@""];
        [identity setEnabled:NO];
        [menu addItem:identity];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    BOOL isPlaying = [current.playbackStatus isEqualToString:GSMediaPlayer2Playing];
    /* Here the glyph goes with the label and says what the item WILL do, so
       a paused player offers "Play ▶" - which is the opposite of what the
       menu bar shows for that same state, and deliberately so.  The bar is a
       readout of what is happening; this is a list of what you can ask for,
       and a command that named the current state instead of the action
       would read as a claim rather than an offer. */
    [menu addItem:[self transportItemWithTitle:(isPlaying ? @"Pause" : @"Play")
                                         action:@selector(togglePlayPause:)
                                           icon:(isPlaying ? @"media-pause" : @"media-play")]];
    [menu addItem:[self transportItemWithTitle:@"Next"
                                         action:@selector(next:)
                                           icon:@"media-next"]];
    [menu addItem:[self transportItemWithTitle:@"Previous"
                                         action:@selector(previous:)
                                           icon:@"media-previous"]];
    [menu addItem:[self transportItemWithTitle:@"Stop"
                                         action:@selector(stop:)
                                           icon:@"media-stop"]];

    if ([players count] > 1) {
        [menu addItem:[NSMenuItem separatorItem]];
        for (MediaPlayerEntry *player in players) {
            /* One player per item, with the one the commands go to ticked,
               the way a menu shows which of several it is acting on. */
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:player.identity
                                                         action:@selector(usePlayer:)
                                                  keyEquivalent:@""];
            [item setTarget:self];
            [item setRepresentedObject:player.identifier];
            [item setState:[player.identifier isEqualToString:current.identifier] ? NSOnState : NSOffState];
            [menu addItem:item];
        }
    }

    return menu;
}

- (NSMenuItem *)transportItemWithTitle:(NSString *)title
                                action:(SEL)action
                                  icon:(NSString *)iconName
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    [item setTarget:self];
    /* The icons are drawn on the menu's own background rather than the menu
       bar's, so they are asked for at the size a menu item draws them
       instead of the size the bar does. */
    NSImage *icon = [NSImage imageNamed:iconName];
    if (icon != nil) {
        [icon setSize:NSMakeSize(kItemIconSize, kItemIconSize)];
        [item setImage:icon];
    }
    return item;
}

/* "Title - Artist", or just the title, or nothing at all: a player that
   says neither is named by its identity instead, further up the menu. */
- (NSString *)nowPlayingForEntry:(MediaPlayerEntry *)entry
{
    NSString *title = entry.title;
    if ([title length] == 0) return nil;

    NSString *artist = entry.artist;
    if ([artist length] == 0) return title;
    return [NSString stringWithFormat:@"%@ - %@", title, artist];
}

#pragma mark - Actions

- (void)togglePlayPause:(id)sender
{
    (void)sender;
    if ([_hub playPause]) {
        [self expectTheOppositeState];
    }
}

- (void)next:(id)sender
{
    (void)sender;
    [_hub next];
    [_hub refresh];
}

- (void)previous:(id)sender
{
    (void)sender;
    [_hub previous];
    [_hub refresh];
}

- (void)stop:(id)sender
{
    (void)sender;
    if ([_hub stop]) {
        [self forgetExpectedState];
    }
}

- (void)usePlayer:(id)sender
{
    NSString *identifier = [sender representedObject];
    if (![identifier isKindOfClass:[NSString class]]) return;
    if ([_hub usePlayerWithIdentifier:identifier]) {
        /* The icon belongs to the player that was picked, not to the one it
           replaces. */
        _expectedStatus = nil;
        [self redrawNow];
    }
}

/* The player acts on the command on its own thread and says so through the
   hub a moment later, so the item shows the state that was asked for at
   once, and the state that comes back replaces it.  What is predicted is the
   state, not the icon: which glyph that state wears is -image's business, so
   this stays right whichever way the icons point. */
- (void)expectTheOppositeState
{
    MediaPlayerEntry *player = [_hub currentPlayer];
    if (player == nil) return;

    _expectedStatus = [player.playbackStatus isEqualToString:GSMediaPlayer2Playing]
                    ? GSMediaPlayer2Paused : GSMediaPlayer2Playing;
    [self redrawNow];
    [_hub refresh];
}

/* Stop leaves nothing playing and nothing to press play on, so the bar has
   nothing to promise and only the state the player reports counts. */
- (void)forgetExpectedState
{
    if (_expectedStatus == nil) return;
    _expectedStatus = nil;
    [self redrawNow];
    [_hub refresh];
}

#pragma mark - Redrawing

/* The state the menu bar shows, in one string: what is playing, what it is
   doing, what was expected of it, and how many players there are.  A poll
   that finds the same thing does nothing at all. */
- (NSString *)stateSignature
{
    MediaPlayerEntry *player = [_hub currentPlayer];
    if (player == nil) return [NSString stringWithFormat:@"none|%@", _expectedStatus];
    return [NSString stringWithFormat:@"%@|%@|%lu|%@",
            player.identifier, player.playbackStatus,
            (unsigned long)[[_hub knownPlayers] count],
            _expectedStatus];
}

/* Whether this extra wants any room in the bar at all.
 *
 * A width of 0 is not the same as being absent, because the bar's own
 * padding is added on top of whatever width an item asks for: an item that
 * asks for nothing still reserves that padding, which shows up as a gap with
 * nothing in it.  An extra with nothing to say therefore has to leave the
 * bar altogether, which is what this says - the manager takes the item out
 * of the menu and puts it back when this goes false again.
 *
 * Extras that always have something to show need not implement it. */
- (BOOL)isHiddenFromMenuBar
{
    return [_hub currentPlayer] == nil;
}

- (void)redrawNow
{
    _shownState = nil;
    [self redrawIfChanged];
}

- (void)redrawIfChanged
{
    NSString *signature = [self stateSignature];
    if (_shownState != nil && [signature isEqualToString:_shownState]) return;
    _shownState = signature;
    /* The state moved, so the width that was measured for the old one is
       stale: a player may have arrived, or gone, and that is the difference
       between taking up room in the bar and taking up none. */
    [_context invalidateWidth];
    [_context invalidatePresentation];
}

@end
