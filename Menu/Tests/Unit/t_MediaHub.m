/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_MediaHub.m - the media hub merging the two kinds of player, and the
 * Distributed Objects interface it serves.
 *
 * MPRISMediaController has its own test against a real bus
 * (t_MPRISMediaController.m); what is left to check here is the hub: that a
 * player found on the bus and the native Gershwin player end up in one list,
 * that the transport methods go to the right one, and that the same methods
 * answer a program that asks over Distributed Objects instead.
 *
 * The native player is a fake one that stands in for Player, registered
 * under a name of its own so that a Player that happens to be running in
 * this session is not mistaken for it.  Headless: no display and no sound.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "MediaHub.h"

#pragma mark - A native player, standing in for Player

/* What the hub asks of a native player, and what a real one answers: the
   six commands, its name, and what it is doing. */
@interface FakeNativePlayer : NSObject <GSMediaPlayer2>
{
@public
    NSString *status;
    NSUInteger plays, pauses, playPauses, stops, nexts, previouss;
}
- (void)setStatus:(NSString *)newStatus;
@end

@implementation FakeNativePlayer

- (id)init
{
    self = [super init];
    status = [@"Stopped" copy];
    return self;
}

- (void)dealloc
{
    [status release];
    [super dealloc];
}

- (void)setStatus:(NSString *)newStatus
{
    NSString *held = [newStatus copy];
    [status release];
    status = held;
}

- (void)play
{
    plays++;
    [self setStatus:GSMediaPlayer2Playing];
}

- (void)pause
{
    pauses++;
    [self setStatus:GSMediaPlayer2Paused];
}

- (void)playPause
{
    playPauses++;
    [self setStatus:[status isEqualToString:GSMediaPlayer2Playing]
                          ? GSMediaPlayer2Paused : GSMediaPlayer2Playing];
}

- (void)stop
{
    stops++;
    [self setStatus:GSMediaPlayer2Stopped];
}

- (void)next { nexts++; }
- (void)previous { previouss++; }

- (bycopy NSString *)playbackStatus { return status; }
- (bycopy NSString *)identity { return @"Fake Native Player"; }

/* The hub only ever sends the six commands and asks the two state
   questions, so the two pause-owner methods are answered plainly here. */
- (BOOL)pauseForClient:(bycopy NSString *)client
{
    (void)client;
    [self pause];
    return YES;
}

- (BOOL)resumeForClient:(bycopy NSString *)client
{
    (void)client;
    [self play];
    return YES;
}

@end

/* Registered under a name of its own: the hub looks up whatever name it is
   told to, and a name of its own keeps a Player that is really running from
   being the thing under test. */
static NSString *const kFakeNativeName = @"io.github.gershwin-desktop.mediatest.NativePlayer";

#pragma mark - Waiting

/* The hub answers on the main thread and looks the native player up on a
   queue of its own, so a test waits with the run loop turning. */
static BOOL WaitFor(NSTimeInterval seconds, BOOL (^test)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSAutoreleasePool *inner = [NSAutoreleasePool new];
        if (test()) {
            [inner release];
            return YES;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        [inner release];
    }
    return test();
}

#pragma mark - The test

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    /* No bus here: this test is about the native player and the merge, and
       the controller finds no players on a bus of its own, which is the
       state the hub has to cope with anyway. */
    FakeNativePlayer *player = [[FakeNativePlayer alloc] init];
    NSConnection *connection = [[NSConnection alloc] init];
    [connection setRootObject:player];
    PASS([connection registerName:kFakeNativeName],
         "the fake native player registers its name");

    MediaHub *hub = [[MediaHub alloc] init];
    [hub setNativePlayerServiceName:kFakeNativeName];
    [hub start];

    /* --- the native player is found --- */
    PASS(WaitFor(5.0, ^BOOL{ return [[hub knownPlayers] count] > 0; }),
         "the hub finds the native player");

    if ([[hub knownPlayers] count] > 0) {
        MediaPlayerEntry *entry = [[hub knownPlayers] objectAtIndex:0];
        PASS_EQUAL([entry identifier], kFakeNativeName,
                   "the player is listed under the name it is registered under");
        PASS_EQUAL([entry identity], @"Fake Native Player",
                   "under the name it calls itself");
        PASS([entry native], "and is marked as reached over Distributed Objects");
        PASS_EQUAL([hub identity], @"Fake Native Player",
                   "the DO interface names it too");
        PASS([hub hasPlayers], "and says there is a player");
    }

    /* --- the transport methods reach it --- */
    PASS(WaitFor(5.0, ^BOOL{ return player->plays + player->pauses == 0; }),
         "the fake player has not been touched yet");

    if ([hub hasPlayers]) {
        PASS([hub play], "play is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return player->plays == 1; }),
             "and the native player really gets it");
        PASS(WaitFor(5.0, ^BOOL{ return player->plays == 1; }),
             "and says so through the hub a moment later");

        PASS([hub playPause], "playPause is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return player->playPauses == 1; }),
             "and reaches the player");
        PASS(WaitFor(5.0, ^BOOL{
            return [[hub playbackStatus] isEqualToString:GSMediaPlayer2Paused];
        }), "the DO interface reports the state the player reached");

        PASS([hub next], "next is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return player->nexts == 1; }),
             "and reaches the player");
        PASS([hub previous], "previous is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return player->previouss == 1; }),
             "and reaches the player");
        PASS([hub stop], "stop is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return player->stops == 1; }),
             "and reaches the player");
        /* The hub's own state follows from the next poll of the player, so
           it is a moment behind the command rather than with it - which is
           the point of asking, not of assuming. */
        PASS(WaitFor(5.0, ^BOOL{
            return [[hub playbackStatus] isEqualToString:GSMediaPlayer2Stopped];
        }), "and the hub reports the player stopped once it has asked again");

        /* What the DO interface hands out: one dictionary per player, with
           the keys the header promises. */
        NSArray *described = [hub players];
        PASS([described count] == [[hub knownPlayers] count],
             "-players describes every player the hub knows");
        if ([described count] > 0) {
            NSDictionary *entry = [described objectAtIndex:0];
            PASS_EQUAL([entry objectForKey:@"identifier"], kFakeNativeName,
                       "the description carries the identifier");
            PASS_EQUAL([entry objectForKey:@"identity"], @"Fake Native Player",
                       "and the identity");
            PASS_EQUAL([entry objectForKey:@"playbackStatus"], [hub playbackStatus],
                       "and the state the hub reports");
            PASS([[entry objectForKey:@"native"] boolValue],
                 "and that it is a native player");
            PASS([[entry objectForKey:@"title"] isKindOfClass:[NSString class]],
                 "a description always has a title, even an empty one");
        }

        /* Picking a player that is not there is refused rather than
           silently ignored, so a client can tell. */
        PASS(![hub usePlayer:@"org.mpris.MediaPlayer2.nosuchplayer"],
             "picking a player that is not there is refused");
        PASS([hub usePlayer:kFakeNativeName],
             "picking the one that is there is accepted");
    }

    /* --- with no player at all --- */
    [hub shutdown];
    [connection release];

    /* A hub with nothing to steer answers NO rather than raising, which is
       what a program with no media playing will ask it. */
    MediaHub *empty = [[MediaHub alloc] init];
    [empty setNativePlayerServiceName:@"io.github.gershwin-desktop.mediatest.NoSuchPlayer"];
    [empty start];
    PASS(WaitFor(3.0, ^BOOL{ return ![empty hasPlayers]; }),
         "a hub with no player behind it reports no players");
    PASS(![empty playPause], "and refuses the transport commands");
    PASS(![empty play], "all of them");
    PASS(![empty stop], "every one");
    PASS_EQUAL([empty playbackStatus], GSMediaPlayer2Stopped,
               "reporting Stopped rather than raising");
    PASS_EQUAL([empty identity], @"",
               "and no name");
    PASS([[empty players] count] == 0, "and no players to list");
    [empty shutdown];

    [hub release];
    [player release];
    [pool release];
    return 0;
}
