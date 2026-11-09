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
    [watcherName release];
    [super dealloc];
}

/* Tells a subscriber that the state moved, if it did.  The player calls this
   when the user moves playback from its own window, which never passes
   through the transport methods below. */
- (void)playbackStateDidChange:(NSString *)wasStatus
{
    if (!StatusIs([player mediaRemotePlaybackStatus], wasStatus)) {
        [self tellWatcherStateChanged];
    }
}

#pragma mark - Saying that something changed

/* GSMediaPlayer2: the client that shows this player's state rather than only
   steering it - Menu's media extra - is told to look again. */
- (BOOL)subscribeWatcher:(bycopy NSString *)serviceName
{
    if ([serviceName length] == 0) {
        return NO;
    }
    [serviceName retain];
    [watcherName release];
    watcherName = serviceName;
    return YES;
}

- (oneway void)stateDidChange
{
    // What a subscriber does with this; the player never calls it on itself.
    return;
}

/* Tells the subscriber, if there is one, that the state moved.  A name and
   not a stored connection: an NSConnection cannot be encoded across
   Distributed Objects on this runtime, so a client that had handed one over
   would have got an exception instead of a subscription.  One name is
   looked up per change - a local round trip to a name server that is already
   running, and nothing beside the playback it sits between.

   A subscriber that has gone away is forgotten rather than complained about:
   a watcher that quit is not the player's problem, and looking it up again
   on every track change would be. */
- (void)tellWatcherStateChanged
{
    if (watcherName == nil) {
        return;
    }

    NSDistantObject *proxy = nil;
    @try {
        proxy = [NSConnection rootProxyForConnectionWithRegisteredName:watcherName
                                                                   host:nil];
    } @catch (NSException *e) {
        proxy = nil;
    }
    if (proxy == nil) {
        [watcherName release];
        watcherName = nil;
        return;
    }

    @try {
        /* Typed as the protocol, so the call is checked here rather than
           sent to a proxy that would raise on the far side. */
        id<GSMediaPlayer2> watcher = (id<GSMediaPlayer2>)proxy;
        /* oneway: the player is starting or stopping a track here and must
           not wait for the listener to be ready. */
        [watcher stateDidChange];
    } @catch (NSException *e) {
        [watcherName release];
        watcherName = nil;
    }
}

#pragma mark - The pause a client holds

/* Ends a pause whose status no longer matches what the player is doing.
 * This is bookkeeping, not a signal: -playbackStatus calls it, and a
 * question is not a change.  It says nothing to the watcher - see
 * -stateDidChange, which is called only from the places where the player
 * really moved. */
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

/* Tells the watcher that the state moved - but only when it did.
 *
 * A watcher exists to be told when the player starts or stops, and this is
 * a round trip to a name server and a message across a socket, so it is
 * spent only on a real transition.  That is the whole point of comparing
 * before and after: the player can be asked to pause while it is already
 * paused, and being asked is not a change.
 *
 * The status is read after the command, not before, because the player acts
 * on the command and the watcher must not be sent off to look at a state the
 * player has not left yet. */
- (void)didChangePlaybackTo:(NSString *)wasStatus
{
    if (!StatusIs([player mediaRemotePlaybackStatus], wasStatus)) {
        [self tellWatcherStateChanged];
    }
}

- (void)play
{
    // The player plays for a reason of its own now: any pause ends here
    [self dropPause];
    NSString *was = [player mediaRemotePlaybackStatus];
    [player mediaRemotePlay];
    [self didChangePlaybackTo:was];
}

- (void)pause
{
    [self notePlaybackChanged];
    if (StatusIs([player mediaRemotePlaybackStatus], GSMediaPlayer2Playing)) {
        NSString *was = [player mediaRemotePlaybackStatus];
        [player mediaRemotePause];
        [self didChangePlaybackTo:was];
    }
}

- (void)playPause
{
    [self dropPause];
    NSString *was = [player mediaRemotePlaybackStatus];
    if (StatusIs(was, GSMediaPlayer2Playing)) {
        [player mediaRemotePause];
    } else {
        [player mediaRemotePlay];
    }
    [self didChangePlaybackTo:was];
}

- (void)stop
{
    // The player stops for a reason of its own now: any pause ends here
    [self dropPause];
    NSString *was = [player mediaRemotePlaybackStatus];
    [player mediaRemoteStop];
    [self didChangePlaybackTo:was];
}

- (void)next
{
    NSString *was = [player mediaRemotePlaybackStatus];
    [player mediaRemoteNext];
    [self notePlaybackChanged];
    // The item changed; whether the state did is the player's to say.
    if (!StatusIs([player mediaRemotePlaybackStatus], was)) {
        [self tellWatcherStateChanged];
    }
}

- (void)previous
{
    NSString *was = [player mediaRemotePlaybackStatus];
    [player mediaRemotePrevious];
    [self notePlaybackChanged];
    if (!StatusIs([player mediaRemotePlaybackStatus], was)) {
        [self tellWatcherStateChanged];
    }
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
