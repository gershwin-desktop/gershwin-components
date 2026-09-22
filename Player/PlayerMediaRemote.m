/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerMediaRemote.h"

static BOOL StatusIs(NSString *status, NSString *want)
{
    return status != nil && [status isEqualToString:want];
}

@implementation PlayerMediaRemote

- (id)initWithPlayer:(id<PlayerMediaRemoteTarget>)aPlayer
{
    self = [super init];
    if (self) {
        player = aPlayer; // not retained: the player owns this object
    }
    return self;
}

- (void)dealloc
{
    [pauseClient release];
    [pausedStatus release];
    [super dealloc];
}

#pragma mark - The pause a client holds

- (void)notePlaybackChanged
{
    if (pauseClient == nil) {
        return;
    }
    // The pause is in effect only while the player still sits in the very
    // status the pause left it in; anything else it did ends the pause
    if (pausedStatus != nil
        && StatusIs([player mediaRemotePlaybackStatus], pausedStatus)) {
        return;
    }
    [pauseClient release];
    pauseClient = nil;
    [pausedStatus release];
    pausedStatus = nil;
}

- (void)dropPause
{
    [pauseClient release];
    pauseClient = nil;
    [pausedStatus release];
    pausedStatus = nil;
}

#pragma mark - GSMediaPlayer2: transport

- (void)play
{
    // The player plays for a reason of its own now: any pause ends here
    [self dropPause];
    [player mediaRemotePlay];
}

- (void)pause
{
    [self notePlaybackChanged];
    if (StatusIs([player mediaRemotePlaybackStatus], GSMediaPlayer2Playing)) {
        [player mediaRemotePause];
    }
}

- (void)playPause
{
    [self dropPause];
    if (StatusIs([player mediaRemotePlaybackStatus], GSMediaPlayer2Playing)) {
        [player mediaRemotePause];
    } else {
        [player mediaRemotePlay];
    }
}

- (void)stop
{
    // The player stops for a reason of its own now: any pause ends here
    [self dropPause];
    [player mediaRemoteStop];
}

- (void)next
{
    [player mediaRemoteNext];
    [self notePlaybackChanged];
}

- (void)previous
{
    [player mediaRemotePrevious];
    [self notePlaybackChanged];
}

#pragma mark - GSMediaPlayer2: state

- (bycopy NSString *)playbackStatus
{
    [self notePlaybackChanged];
    return [player mediaRemotePlaybackStatus];
}

- (bycopy NSString *)identity
{
    return @"Player";
}

#pragma mark - GSMediaPlayer2: pausing for one client

- (BOOL)pauseForClient:(bycopy NSString *)client
{
    if ([client length] == 0) {
        return NO;
    }
    [self notePlaybackChanged];
    if (pauseClient != nil) {
        // One pause, one owner: YES again for that owner, NO for the rest
        return [pauseClient isEqualToString:client];
    }
    if (!StatusIs([player mediaRemotePlaybackStatus], GSMediaPlayer2Playing)) {
        // Nothing plays, or the player is paused for the user - not ours
        return NO;
    }
    [player mediaRemotePause];
    [pausedStatus release];
    pausedStatus = [[player mediaRemotePlaybackStatus] copy];
    pauseClient = [client copy];
    return YES;
}

- (BOOL)resumeForClient:(bycopy NSString *)client
{
    if ([client length] == 0) {
        return NO;
    }
    [self notePlaybackChanged];
    if (pauseClient == nil || ![pauseClient isEqualToString:client]) {
        // Held nothing (perhaps the player moved on): the caller must not
        // assume the player is playing now
        return NO;
    }
    [self dropPause];
    [player mediaRemotePlay];
    return YES;
}

@end
