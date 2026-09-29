/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MediaHub.h"

#import "GSMediaPlayer2.h"
#import "MPRISMediaController.h"

#import <dispatch/dispatch.h>

NSString * const MediaHubChangedNotification = @"MediaHubChangedNotification";

/* How often the native player is asked what it is doing, in seconds.  A
   native player says nothing when it changes, so this is the only way to
   know; it is a Distributed Objects call to a program in the same session,
   which answers at once or not at all. */
static const uint64_t kNativePollSeconds = 2;

/* How long one call to the native player waits, in seconds.  A player that
   has gone away is a player that does not answer, and must not hold up the
   poll. */
static const NSTimeInterval kNativeCallTimeout = 1.0;

#pragma mark - One player

@interface MediaPlayerEntry ()
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *identity;
@property (nonatomic, copy) NSString *playbackStatus;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, assign) BOOL native;
- (NSDictionary *)dictionaryRepresentation;
@end

/* Everything the extra and the DO interface show about one player, in one
   string, so that a rebuild can tell whether anything the user can see has
   changed. */
static NSString *MediaPlayerSignature(MediaPlayerEntry *entry)
{
    if (entry == nil) return @"";
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%d",
            entry.identifier, entry.playbackStatus, entry.title, entry.artist,
            entry.native ? 1 : 0];
}

static NSString *MediaPlayersSignature(NSArray<MediaPlayerEntry *> *entries)
{
    NSMutableArray *signatures = [NSMutableArray arrayWithCapacity:[entries count]];
    for (MediaPlayerEntry *entry in entries) {
        [signatures addObject:MediaPlayerSignature(entry)];
    }
    return [signatures componentsJoinedByString:@";"];
}

@implementation MediaPlayerEntry

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %@ (%@)%@>",
            [self class], _identity, _playbackStatus, _native ? @" native" : @""];
}

/* What the DO interface hands out, and the shape the header describes. */
- (NSDictionary *)dictionaryRepresentation
{
    return @{
        @"identifier": _identifier ?: @"",
        @"identity": _identity ?: @"",
        @"playbackStatus": _playbackStatus ?: GSMediaPlayer2Stopped,
        @"title": _title ?: @"",
        @"artist": _artist ?: @"",
        @"native": [NSNumber numberWithBool:_native],
    };
}

@end

#pragma mark - The hub

@interface MediaHub ()
{
    MPRISMediaController *_mpris;
    NSConnection *_serviceConnection;

    /* MPRIS players, as the bus reported them, and the native one.  Both
       are read and written on the main thread only. */
    NSArray<NSDictionary *> *_mprisPlayers;
    MediaPlayerEntry *_nativePlayer;
    NSString *_chosenIdentifier;
    NSArray<MediaPlayerEntry *> *_knownPlayers;
    MediaPlayerEntry *_currentPlayer;

    /* The native side.  Its calls can block for as long as a call may, so
       they are made on a queue of their own and never on the main thread. */
    dispatch_queue_t _nativeQueue;
    dispatch_source_t _nativeTimer;
    id<GSMediaPlayer2> _nativeProxy;
    /* The connection the player pushes -stateDidChange on.  Its receive port
       is in the MAIN run loop, not on the native queue: a dispatch queue has
       no run loop to put a port in, and a oneway message that arrives
       nowhere is worse than a poll.  The handler therefore does nothing but
       hand the re-read to the native queue. */
    NSConnection *_subscriberConnection;
    NSString *_watcherName;
    BOOL _subscribed;
    BOOL _started;
}
@end

@implementation MediaHub

+ (instancetype)sharedHub
{
    static MediaHub *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[MediaHub alloc] init];
            [shared setNativePlayerServiceName:GSMediaPlayer2PlayerServiceName];
            [shared start];
        }
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _mpris = [[MPRISMediaController alloc] init];
        _mprisPlayers = @[];
        _knownPlayers = @[];
        _nativePlayerServiceName = GSMediaPlayer2PlayerServiceName;
    }
    return self;
}

- (void)dealloc
{
    [self shutdown];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark - Starting and stopping

/* Starts the hub: the bus worker, the poll of the native player, and the
   service other programs call into.  Answers whether it is running. */
- (BOOL)start
{
    @synchronized(self) {
        if (_started) return YES;
        _started = YES;
    }

    /* The service name is taken FIRST, before any thread of ours exists.
     * That order is not tidiness, it is a deadlock this hub caused and then
     * removed.
     *
     * Registering a Distributed Objects name first-touches NSConnection,
     * which first-touches NSCoder, which first-touches NSUserDefaults,
     * which posts a change notification that NSSTimeZone answers by
     * re-reading itself - and it does that while holding zone_mutex, a
     * plain mutex that is not reentrant.  So a thread that is halfway
     * through registering a name holds the defaults lock and wants the time
     * zone lock.
     *
     * The native poll below builds an NSConnection of its own, from another
     * thread, at the same moment, and goes for the time zone lock first
     * (any GNUstep log line is stamped with the time).  Two threads, two
     * locks, opposite order, and the whole thing wedges - with Menu's main
     * thread inside it, before the menu bar has drawn anything.
     *
     * Registering here, alone, means the classes are already initialised by
     * the time the poll starts, so there is no second thread in the middle
     * of a first touch. */
    [self registerService];

    _nativeQueue = dispatch_queue_create("io.github.gershwin-components.Menu.MediaHub",
                                         DISPATCH_QUEUE_SERIAL);
    _nativeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _nativeQueue);
    /* Asked at once, so a player that is already running is known before
       anything asks about it. */
    dispatch_source_set_timer(_nativeTimer, DISPATCH_TIME_NOW,
                              kNativePollSeconds * NSEC_PER_SEC,
                              250 * NSEC_PER_MSEC);
    __weak MediaHub *weakSelf = self;
    dispatch_source_set_event_handler(_nativeTimer, ^{
        @autoreleasepool {
            [weakSelf pollNativePlayer];
        }
    });
    dispatch_resume(_nativeTimer);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(mprisChanged:)
                                                 name:MPRISMediaControllerChangedNotification
                                               object:nil];

    /* Made here, on the main thread, before the native queue exists: its
       receive port goes in the main run loop, and a run loop is not
       something another thread may reach into.  The native queue asks for it
       later and finds it waiting. */
    [self subscriberConnection];

    if (![_mpris start]) {
        NSDebugLLog(@"gwcomp", @"MediaHub: no session bus, the MPRIS players are not there");
    }

    return YES;
}

/* Stops the hub: no more polls, no more bus worker, and the service name
   given up.  Not called -stop, which is the Player interface's, and is what
   the extra and every other client press. */
- (void)shutdown
{
    @synchronized(self) {
        if (!_started) return;
        _started = NO;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_nativeTimer != nil) {
        dispatch_source_cancel(_nativeTimer);
        _nativeTimer = nil;
    }
    _nativeProxy = nil;

    [_mpris stop];
    _mpris = nil;
    _serviceConnection = nil;
    _subscriberConnection = nil;
    _watcherName = nil;
    _subscribed = NO;
    _nativeQueue = nil;
}

/* The name other programs look Media up under.  A dedicated connection, not
   the default one, for the reason the global menu server gives: a name
   registered on the default connection cannot be registered again, so a name
   server that was restarted would leave Media unreachable forever. */
- (void)registerService
{
    NSConnection *connection = [[NSConnection alloc] init];
    [connection setRootObject:self];

    BOOL registered = NO;
    @try {
        registered = [connection registerName:GSMediaControlServiceName];
    } @catch (NSException *e) {
        registered = NO;
        NSDebugLLog(@"gwcomp", @"MediaHub: cannot register %@: %@", GSMediaControlServiceName, e);
    }
    if (!registered) {
        NSDebugLLog(@"gwcomp", @"MediaHub: could not register %@, the DO interface is not served",
                    GSMediaControlServiceName);
        return;
    }

    _serviceConnection = connection;
    NSPort *receivePort = [connection receivePort];
    if (receivePort != nil) {
        @try {
            [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
        } @catch (NSException *e) {
            NSDebugLLog(@"gwcomp", @"MediaHub: cannot serve on the run loop: %@", e);
        }
    }
    NSDebugLLog(@"gwcomp", @"MediaHub: serving %@", GSMediaControlServiceName);
}

/* The connection the native player pushes -stateDidChange on, made once and
   kept.  Its receive port goes in the main run loop, beside the service
   connection's, so that the push has somewhere to land; the hub itself is
   the root object, so the message arrives as -stateDidChange below.  The
   name it is registered under is kept beside it, because that name is what
   the player is told to call. */
- (NSString *)watcherName
{
    if (_watcherName == nil) {
        [self subscriberConnection];
    }
    return _watcherName;
}

- (NSConnection *)subscriberConnection
{
    if (_subscriberConnection != nil) return _subscriberConnection;

    NSConnection *connection = [[NSConnection alloc] init];
    [connection setRootObject:self];
    NSPort *receivePort = [connection receivePort];
    if (receivePort == nil) {
        NSDebugLLog(@"gwcomp", @"MediaHub: the watcher connection has no port");
        return nil;
    }
    /* The name the player is given to call back on.  A name rather than a
       connection handed over in the call, because an NSConnection cannot be
       encoded across Distributed Objects on this runtime: -subscribeWatcher:
       would raise instead of subscribing. */
    NSString *name = [NSString stringWithFormat:@"%@.Watcher.%d",
                      GSMediaControlServiceName, (int)getpid()];
    if (![connection registerName:name]) {
        NSDebugLLog(@"gwcomp", @"MediaHub: cannot register %@ for state changes", name);
        return nil;
    }
    @try {
        [[NSRunLoop currentRunLoop] addPort:receivePort forMode:NSRunLoopCommonModes];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"MediaHub: cannot take state changes: %@", e);
        return nil;
    }
    _watcherName = name;
    _subscriberConnection = connection;
    return connection;
}

/* GSMediaPlayer2, from the player to us: something moved.  All this does is
   ask the player again - on the native queue, because asking is a call that
   can block and this arrives on the main thread where a blocked call would
   freeze the menu bar.  The poll stays as the backstop for a player too old
   to have -subscribe:, so a hub with no subscription still works. */
- (oneway void)stateDidChange
{
    dispatch_queue_t queue = _nativeQueue;
    if (queue == nil) return;
    dispatch_async(queue, ^{
        @autoreleasepool {
            [self pollNativePlayer];
        }
    });
}

#pragma mark - The MPRIS side

- (void)mprisChanged:(NSNotification *)notification
{
    (void)notification;
    /* Already on the main thread: the notification is posted there. */
    _mprisPlayers = [_mpris players];
    [self rebuild];
}

- (void)rebuild
{
    NSMutableArray<MediaPlayerEntry *> *entries = [NSMutableArray array];

    for (NSDictionary *player in _mprisPlayers) {
        MediaPlayerEntry *entry = [[MediaPlayerEntry alloc] init];
        entry.identifier = [player objectForKey:MPRISPlayerBusNameKey];
        entry.identity = [player objectForKey:MPRISPlayerIdentityKey];
        entry.playbackStatus = [player objectForKey:MPRISPlayerStatusKey] ?: GSMediaPlayer2Stopped;
        entry.title = [player objectForKey:MPRISPlayerTitleKey];
        entry.artist = [player objectForKey:MPRISPlayerArtistKey];
        entry.native = NO;
        [entries addObject:entry];
    }
    if (_nativePlayer != nil) {
        [entries addObject:_nativePlayer];
    }

    MediaPlayerEntry *current = nil;
    if (_chosenIdentifier != nil) {
        for (MediaPlayerEntry *entry in entries) {
            if ([entry.identifier isEqualToString:_chosenIdentifier]) {
                current = entry;
                break;
            }
        }
        /* A player that was picked and is gone is not picked any more, so
           that the hub does not wait for it to come back before steering
           whatever plays now. */
        if (current == nil) _chosenIdentifier = nil;
    }
    if (current == nil) {
        for (MediaPlayerEntry *entry in entries) {
            if ([entry.playbackStatus isEqualToString:GSMediaPlayer2Playing]) {
                current = entry;
                break;
            }
        }
    }
    if (current == nil) {
        current = [entries firstObject];
    }

    BOOL changed = ![MediaPlayersSignature(entries) isEqualToString:MediaPlayersSignature(_knownPlayers)];

    _knownPlayers = entries;
    _currentPlayer = current;

    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:MediaHubChangedNotification
                                                            object:self];
    }
}

#pragma mark - The native side

/* Runs on the native queue, never on the main thread. */
- (void)pollNativePlayer
{
    id<GSMediaPlayer2> proxy = [self nativePlayerProxy];
    if (proxy == nil) {
        [self takeNativePlayer:nil];
        return;
    }

    NSString *identity = nil;
    NSString *status = nil;
    BOOL alive = YES;
    @try {
        identity = [proxy identity];
        status = [proxy playbackStatus];
    } @catch (NSException *e) {
        /* The player went away between the lookup and the question.  The
           proxy is dropped so that the next poll looks it up again. */
        NSDebugLLog(@"gwcomp", @"MediaHub: the native player is gone: %@", e);
        _nativeProxy = nil;
        alive = NO;
    }
    if (!alive) {
        [self takeNativePlayer:nil];
        return;
    }

    MediaPlayerEntry *entry = [[MediaPlayerEntry alloc] init];
    entry.identifier = _nativePlayerServiceName;
    entry.identity = [identity length] > 0 ? identity : @"Player";
    entry.playbackStatus = [status length] > 0 ? status : GSMediaPlayer2Stopped;
    /* MPRIS metadata has no place in the native interface, so a native
       player says what it is playing only by doing it. */
    entry.title = @"";
    entry.artist = @"";
    entry.native = YES;
    [self takeNativePlayer:entry];
}

/* The proxy for the native player, looked up once and kept until it stops
   answering, so that a player that is running costs one name lookup rather
   than one per call. */
- (id<GSMediaPlayer2>)nativePlayerProxy
{
    if (_nativeProxy != nil) return _nativeProxy;
    if ([_nativePlayerServiceName length] == 0) return nil;

    @try {
        NSDistantObject *proxy = [NSConnection rootProxyForConnectionWithRegisteredName:_nativePlayerServiceName
                                                                                 host:nil];
        if (proxy == nil) return nil;   // no such player is running
        [proxy setProtocolForProxy:@protocol(GSMediaPlayer2)];
        NSConnection *connection = [proxy connectionForProxy];
        [connection setRequestTimeout:kNativeCallTimeout];
        [connection setReplyTimeout:kNativeCallTimeout];
        /* The poll is on a queue of its own, but a call can be re-entered
           by a program that calls back into Media from its own side. */
        [connection enableMultipleThreads];
        _nativeProxy = (id<GSMediaPlayer2>)proxy;
        [self subscribeToNativePlayer:_nativeProxy];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"MediaHub: cannot reach %@: %@", _nativePlayerServiceName, e);
        _nativeProxy = nil;
    }
    return _nativeProxy;
}

/* Asks the player to push its state changes, once per player.
 *
 * A player that answers YES is told about every change at once, and the
 * two-second poll then only has to catch what a push missed.  A player that
 * does not have the method - one built before this existed - is left to the
 * poll alone, which is why -respondsToSelector: is asked first: sending a
 * method the player does not implement is an exception, not a NO. */
- (void)subscribeToNativePlayer:(id<GSMediaPlayer2>)player
{
    if (_subscribed) return;

    @try {
        if (![player respondsToSelector:@selector(subscribeWatcher:)]) {
            NSDebugLLog(@"gwcomp", @"MediaHub: the native player does not push state changes");
            return;
        }
        NSString *watcher = [self watcherName];
        if (watcher == nil) return;

        if ([player subscribeWatcher:watcher]) {
            _subscribed = YES;
            NSDebugLLog(@"gwcomp", @"MediaHub: taking state changes from %@ on %@",
                        _nativePlayerServiceName, watcher);
        } else {
            NSDebugLLog(@"gwcomp", @"MediaHub: the native player refused the subscription");
        }
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"MediaHub: could not subscribe: %@", e);
    }
}

/* The state of the native player, as the poll found it, becomes the state
   of the main thread. */
- (void)takeNativePlayer:(MediaPlayerEntry *)entry
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([MediaPlayerSignature(entry) isEqualToString:MediaPlayerSignature(self->_nativePlayer)]) {
            return;   // nothing the user can see has changed
        }
        self->_nativePlayer = entry;
        [self rebuild];
    });
}

#pragma mark - GSMediaControl

- (NSArray<MediaPlayerEntry *> *)knownPlayers
{
    return _knownPlayers;
}

- (MediaPlayerEntry *)currentPlayer
{
    return _currentPlayer;
}

- (BOOL)hasPlayers
{
    return ([_knownPlayers count] > 0);
}

- (bycopy NSString *)playbackStatus
{
    return _currentPlayer.playbackStatus ?: GSMediaPlayer2Stopped;
}

- (bycopy NSString *)identity
{
    return _currentPlayer.identity ?: @"";
}

/* What the DO interface hands out: the same players, each as a dictionary
   rather than as an object, because a dictionary survives the trip. */
- (NSArray *)players
{
    NSMutableArray *described = [NSMutableArray arrayWithCapacity:[_knownPlayers count]];
    for (MediaPlayerEntry *entry in _knownPlayers) {
        [described addObject:[entry dictionaryRepresentation]];
    }
    return described;
}

- (BOOL)usePlayerWithIdentifier:(NSString *)identifier
{
    if (![identifier isKindOfClass:[NSString class]]) return NO;
    for (MediaPlayerEntry *entry in _knownPlayers) {
        if ([entry.identifier isEqualToString:identifier]) {
            _chosenIdentifier = [identifier copy];
            [self rebuild];
            return YES;
        }
    }
    return NO;
}

- (BOOL)usePlayer:(bycopy NSString *)identifier
{
    return [self usePlayerWithIdentifier:identifier];
}

- (void)refresh
{
    if (_nativeQueue == nil) return;   // the hub was stopped
    [_mpris requestRefresh];
    /* The native player is asked again at once rather than at the next
       poll; the answer comes back through the same path as a poll. */
    dispatch_async(_nativeQueue, ^{
        @autoreleasepool {
            [self pollNativePlayer];
        }
    });
}

#pragma mark - Transport

/* The transport methods all do the same two things: say whether there was a
   player to send to, and hand the command on.  None of them waits for the
   player, and none of them is answered by the player: a command that was
   sent to a player that has just quit is dropped on its way. */

- (BOOL)sendToCurrentPlayer:(NSString *)mprisMethod
                     native:(void (^)(id<GSMediaPlayer2> player))nativeCommand
{
    MediaPlayerEntry *player = _currentPlayer;
    if (player == nil) return NO;

    if (!player.native) {
        return [_mpris sendCommand:mprisMethod toPlayerWithBusName:player.identifier];
    }

    dispatch_queue_t queue = _nativeQueue;
    if (queue == nil) return NO;   // the hub was stopped under us
    dispatch_async(queue, ^{
        @autoreleasepool {
            id<GSMediaPlayer2> proxy = [self nativePlayerProxy];
            if (proxy == nil) return;
            @try {
                nativeCommand(proxy);
            } @catch (NSException *e) {
                NSDebugLLog(@"gwcomp", @"MediaHub: the native player did not take the command: %@", e);
            }
        }
    });
    return YES;
}

- (BOOL)play
{
    return [self sendToCurrentPlayer:@"Play" native:^(id<GSMediaPlayer2> player) {
        [player play];
    }];
}

- (BOOL)pause
{
    return [self sendToCurrentPlayer:@"Pause" native:^(id<GSMediaPlayer2> player) {
        [player pause];
    }];
}

- (BOOL)playPause
{
    return [self sendToCurrentPlayer:@"PlayPause" native:^(id<GSMediaPlayer2> player) {
        [player playPause];
    }];
}

- (BOOL)stop
{
    return [self sendToCurrentPlayer:@"Stop" native:^(id<GSMediaPlayer2> player) {
        [player stop];
    }];
}

- (BOOL)next
{
    return [self sendToCurrentPlayer:@"Next" native:^(id<GSMediaPlayer2> player) {
        [player next];
    }];
}

- (BOOL)previous
{
    return [self sendToCurrentPlayer:@"Previous" native:^(id<GSMediaPlayer2> player) {
        [player previous];
    }];
}

@end
