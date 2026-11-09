/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_MediaRemote.m - the pause ownership of the media remote: which client
 * holds a pause on Player, and when it ends (MediaRemote/PROTOCOL.md).
 * Headless; a fake player stands in for PlayerController, so no sound and
 * no window are needed. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../../PlayerMediaRemote.m"

/* Stands in for PlayerController: answers with the status the test sets
   and records the commands it was given. */
@interface FakePlayer : NSObject <PlayerMediaRemoteTarget>
{
@public
    NSString *status;
    BOOL radio;
    int plays, pauses, stops, nexts, prevs;
}
- (void)setStatus:(NSString *)newStatus;
@end

@implementation FakePlayer

- (id)init
{
    self = [super init];
    status = [GSMediaPlayer2Stopped copy];
    return self;
}

- (void)dealloc
{
    [status release];
    [super dealloc];
}

- (void)setStatus:(NSString *)newStatus
{
    [status release];
    status = [newStatus copy];
}

- (NSString *)mediaRemotePlaybackStatus
{
    return status;
}

- (void)mediaRemotePlay
{
    plays++;
    [self setStatus:GSMediaPlayer2Playing];
}

- (void)mediaRemotePause
{
    pauses++;
    /* Like the real player: a file pauses, a live stream stops */
    [self setStatus:(radio ? GSMediaPlayer2Stopped : GSMediaPlayer2Paused)];
}

- (void)mediaRemoteStop
{
    stops++;
    [self setStatus:GSMediaPlayer2Stopped];
}

- (void)mediaRemoteNext
{
    nexts++;
}

- (void)mediaRemotePrevious
{
    prevs++;
}

@end

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* --- taking a pause: one pause, one owner --- */
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        PASS([r pauseForClient:@"Whisper-101"],
             "a playing player is paused for the client");
        PASS_EQUAL(f->status, @"Paused", "and reports Paused");
        PASS(f->pauses == 1, "asked to pause exactly once (%d)", f->pauses);

        PASS([r pauseForClient:@"Whisper-101"],
             "the same client asking again is answered YES");
        PASS(f->pauses == 1, "without pausing again (%d)", f->pauses);

        PASS(![r pauseForClient:@"Other-202"],
             "another client is answered NO while one holds the pause");
        PASS(![r resumeForClient:@"Other-202"],
             "and cannot give the pause back");
        PASS_EQUAL(f->status, @"Paused", "the pause stays with its owner");

        PASS([r resumeForClient:@"Whisper-101"],
             "the client that took the pause gives it back");
        PASS(f->plays == 1, "and the player plays again (%d)", f->plays);
        PASS_EQUAL(f->status, @"Playing", "reporting Playing");
        PASS(![r resumeForClient:@"Whisper-101"],
             "a second give-back answers NO");
        PASS(f->plays == 1, "without playing twice (%d)", f->plays);

        [r release];
        [f release];
    }

    /* --- there is nothing to silence --- */
    {
        FakePlayer *f = [FakePlayer new];   /* starts Stopped */
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        PASS(![r pauseForClient:@"Whisper-101"],
             "a stopped player gives no pause");
        PASS(f->pauses == 0, "and is left alone (%d)", f->pauses);

        [f setStatus:GSMediaPlayer2Paused];
        PASS(![r pauseForClient:@"Whisper-101"],
             "a player the user paused gives no pause either");
        PASS(f->pauses == 0, "and stays the user's (%d)", f->pauses);

        [r release];
        [f release];
    }

    /* --- the pause ends when the player moves on for its own reasons --- */
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [f setStatus:GSMediaPlayer2Playing];   /* the user pressed Play */
        [r notePlaybackChanged];
        PASS(![r resumeForClient:@"Whisper-101"],
             "a pause the user played past gives nothing back");
        PASS(f->plays == 0, "and does not play for the client (%d)", f->plays);
        PASS([r pauseForClient:@"Other-202"],
             "once the player plays again, a client can pause it");
        PASS([r resumeForClient:@"Other-202"],
             "and that client owns the new pause");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [f setStatus:GSMediaPlayer2Stopped];   /* the user pressed Stop */
        [r notePlaybackChanged];
        PASS(![r resumeForClient:@"Whisper-101"],
             "a pause the user stopped past gives nothing back");

        [r release];
        [f release];
    }

    /* --- a live stream pauses by stopping --- */
    {
        FakePlayer *f = [FakePlayer new];
        f->radio = YES;
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        PASS([r pauseForClient:@"Whisper-101"],
             "a playing stream is paused for the client");
        PASS_EQUAL(f->status, @"Stopped", "a live stream pauses by stopping");
        PASS([r resumeForClient:@"Whisper-101"],
             "the client gives the pause back");
        PASS(f->plays == 1, "and the station plays again (%d)", f->plays);

        /* The user plays the station past our pause, then stops it again */
        [r pauseForClient:@"Whisper-101"];
        [f setStatus:GSMediaPlayer2Playing];
        [r notePlaybackChanged];
        [f setStatus:GSMediaPlayer2Stopped];
        PASS(![r resumeForClient:@"Whisper-101"],
             "a stream pause the user played past gives nothing back");
        PASS(f->plays == 1, "and does not restart the station (%d)", f->plays);

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        f->radio = YES;
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        PASS([r resumeForClient:@"Whisper-101"],
             "an untouched stream pause is still held at give-back time");

        [r release];
        [f release];
    }

    /* --- transport commands from anyone end the pause --- */
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [r play];
        PASS(f->plays == 1, "-play plays (%d)", f->plays);
        PASS(![r resumeForClient:@"Whisper-101"],
             "-play ends the pause the client held");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [r stop];
        PASS(f->stops == 1, "-stop stops (%d)", f->stops);
        PASS(![r resumeForClient:@"Whisper-101"],
             "-stop ends the pause the client held");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [r playPause];
        PASS(f->plays == 1, "-playPause while paused plays (%d)", f->plays);
        PASS(![r resumeForClient:@"Whisper-101"],
             "-playPause ends the pause the client held");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        [r playPause];
        PASS(f->pauses == 1, "-playPause while playing pauses (%d)", f->pauses);
        PASS(![r pauseForClient:@"Whisper-101"],
             "the plain pause belongs to no client");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        [r pause];
        PASS(f->pauses == 1, "-pause pauses (%d)", f->pauses);
        PASS(![r pauseForClient:@"Whisper-101"],
             "so a pause ask finds the player paused for the user");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];
        [r pauseForClient:@"Whisper-101"];

        [r next];
        [r previous];
        PASS(f->nexts == 1 && f->prevs == 1,
             "-next and -previous forward (%d/%d)", f->nexts, f->prevs);
        PASS([r resumeForClient:@"Whisper-101"],
             "and leave a held pause alone");

        [r release];
        [f release];
    }
    {
        FakePlayer *f = [FakePlayer new];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        PASS(![r pauseForClient:@""], "an empty client token gets NO");
        PASS(![r resumeForClient:@""], "and cannot resume either");
        PASS(![r pauseForClient:nil], "a nil client token gets NO too");

        [r release];
        [f release];
    }

    /* --- status and identity --- */
    {
        FakePlayer *f = [FakePlayer new];
        [f setStatus:GSMediaPlayer2Playing];
        PlayerMediaRemote *r = [[PlayerMediaRemote alloc] initWithPlayer:f];

        PASS_EQUAL([r playbackStatus], @"Playing",
                   "playbackStatus passes on what plays");
        PASS_EQUAL([r identity], @"Player", "identity names the player");
        [f setStatus:GSMediaPlayer2Stopped];
        PASS_EQUAL([r playbackStatus], @"Stopped",
                   "playbackStatus follows the player");

        [r release];
        [f release];
    }

    [arp release];
    return 0;
}
