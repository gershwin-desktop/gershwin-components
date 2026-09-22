/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMediaPlayer2.h"

#include <unistd.h>

NSString * const GSMediaPlayer2Playing = @"Playing";
NSString * const GSMediaPlayer2Paused = @"Paused";
NSString * const GSMediaPlayer2Stopped = @"Stopped";

NSString * const GSMediaPlayer2PlayerServiceName =
    @"io.github.gershwin-desktop.MediaPlayer2.Player";

// Player answers at once or not at all: a media player is either running
// or it is not, and a client waiting longer only holds up whatever it was
// doing (Whisper's dictation service blocks on this call).
static const NSTimeInterval kRequestTimeout = 3.0;

// The one proxy kept for Player, so the connection to it is built once.
// A player that died in the meantime is found again after +forgetPlayer,
// which the retry below does.
static id<GSMediaPlayer2> cachedPlayerProxy = nil;

@implementation GSMediaPlayer2Client

+ (NSString *)clientToken
{
    static NSString *token = nil;
    if (token == nil) {
        token = [[NSString alloc] initWithFormat:@"%@-%d",
                 [[NSProcessInfo processInfo] processName], (int)getpid()];
    }
    return token;
}

+ (id<GSMediaPlayer2>)proxyForService:(NSString *)name
{
    if ([name length] == 0) {
        return nil;
    }
    @try {
        NSDistantObject *proxy =
            [NSConnection rootProxyForConnectionWithRegisteredName:name host:nil];
        if (proxy == nil) {
            return nil;   // no player of that name is running
        }
        [proxy setProtocolForProxy:@protocol(GSMediaPlayer2)];
        NSConnection *connection = [proxy connectionForProxy];
        [connection setRequestTimeout:kRequestTimeout];
        [connection setReplyTimeout:kRequestTimeout];
        // The same client can ask from more than one thread (a service
        // entry point runs on a connection thread of its own)
        [connection enableMultipleThreads];
        return (id<GSMediaPlayer2>)proxy;
    } @catch (NSException *e) {
        NSLog(@"GSMediaPlayer2: cannot reach %@: %@", name, e);
        return nil;
    }
}

+ (id<GSMediaPlayer2>)playerProxy
{
    if (cachedPlayerProxy == nil) {
        cachedPlayerProxy =
            [[self proxyForService:GSMediaPlayer2PlayerServiceName] retain];
    }
    return cachedPlayerProxy;
}

+ (void)forgetPlayer
{
    [cachedPlayerProxy release];
    cachedPlayerProxy = nil;
}

// Runs one question against Player, looking Player up once more when the
// answer never came because the player went away in between.
+ (BOOL)askPlayer:(BOOL (^)(id<GSMediaPlayer2> remote))question
{
    id<GSMediaPlayer2> remote = [self playerProxy];
    if (remote == nil) {
        return NO;
    }
    @try {
        return question(remote);
    } @catch (NSException *e) {
        NSLog(@"GSMediaPlayer2: %@ - looking Player up again", e);
        [self forgetPlayer];
    }
    remote = [self playerProxy];
    if (remote == nil) {
        return NO;
    }
    @try {
        return question(remote);
    } @catch (NSException *e) {
        NSLog(@"GSMediaPlayer2: %@", e);
        [self forgetPlayer];
        return NO;
    }
}

+ (BOOL)pausePlayer
{
    NSString *token = [self clientToken];
    return [self askPlayer:^BOOL(id<GSMediaPlayer2> remote) {
        return [remote pauseForClient:token];
    }];
}

+ (BOOL)resumePlayer
{
    NSString *token = [self clientToken];
    return [self askPlayer:^BOOL(id<GSMediaPlayer2> remote) {
        return [remote resumeForClient:token];
    }];
}

@end
