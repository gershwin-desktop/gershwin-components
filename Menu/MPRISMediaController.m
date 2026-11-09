/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MPRISMediaController.h"

#import <dbus/dbus.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/select.h>
#import <unistd.h>

NSString * const MPRISMediaControllerChangedNotification = @"MPRISMediaControllerChangedNotification";

NSString * const MPRISPlayerBusNameKey = @"busName";
NSString * const MPRISPlayerIdentityKey = @"identity";
NSString * const MPRISPlayerStatusKey = @"playbackStatus";
NSString * const MPRISPlayerTitleKey = @"title";
NSString * const MPRISPlayerArtistKey = @"artist";

/* MPRIS2: a player takes a bus name of the form
   org.mpris.MediaPlayer2.<instance> and answers on this object, where the
   Player interface carries the transport methods and the state.  The bus
   name prefix is what tells a player's name from any other name on the
   session bus. */
static const char *const kPlayerBusPrefix = "org.mpris.MediaPlayer2.";
static const char *const kPlayerObjectPath = "/org/mpris/MediaPlayer2";
static const char *const kPlayerInterface = "org.mpris.MediaPlayer2.Player";
static const char *const kRootInterface = "org.mpris.MediaPlayer2";
static const char *const kDBusInterface = "org.freedesktop.DBus";
static const char *const kPropertiesInterface = "org.freedesktop.DBus.Properties";

/* How long one property query waits for its answer, in milliseconds.  A
   player that does not answer within this is treated as gone, which is what
   a player that has just quit looks like from here. */
static const int kCallTimeoutMS = 1000;

/* How long the worker waits for something to happen before it looks around
   again anyway.  Nothing polls the state through this: it is the backstop
   for a bus that went quiet, and the wake-up the stop path uses. */
static const int kIdleTimeoutMS = 250;

/* How long the worker waits before looking for the bus again after losing
   it, in milliseconds.  A session bus that is restarted comes back in a
   moment, and the extra should notice without anyone asking it to. */
static const int kReconnectDelayMS = 1000;

/* How long the whole bus is read over again even when nothing said
   anything, in seconds.  The signals make the state correct quickly; this
   is what makes it correct at all, since a signal that is never delivered -
   a match rule the bus refused, a player that was already running when this
   connected - would otherwise leave the state wrong for as long as Menu
   runs.  Rare enough to be cheap, near enough that a player that starts on
   its own is noticed while the user is still looking at it. */
static const NSTimeInterval kFullRefreshSeconds = 5.0;

/* The six transport methods of the Player interface.  Only these are ever
   sent, so a caller cannot turn this into a way to call anything at all on
   a bus name it happens to have found. */
static NSString *const kAllowedCommands[] = {
    @"Play", @"Pause", @"PlayPause", @"Stop", @"Next", @"Previous"
};
static const NSUInteger kAllowedCommandCount = sizeof(kAllowedCommands) / sizeof(kAllowedCommands[0]);

#pragma mark - Reading the properties of a player

/* Everything below reads the a{sv} dictionaries the Properties interface
   hands out.  A player is free to return more than the three properties
   this cares about, and is free to return a type this does not know, so the
   parse keeps what it understands, keeps what it does not as an NSNull or a
   nested dictionary, and drops what it cannot make sense of - a player that
   answers with something odd must not be able to stop the menu bar. */

static id MPRISParseValue(DBusMessageIter *iter);

/* One {key, value} of a dictionary.
 *
 * `iter` points AT the entry, the iterator the walk of the enclosing array
 * produced.  A dict entry is a struct, and the only way to read a struct is
 * to recurse into it and walk its fields - asking the entry itself for its
 * type or its value is asking a struct to be a basic type, which libdbus
 * refuses and then aborts on.  The caller's iterator is left where it was,
 * so that it can step on to the next entry itself.
 *
 * A key whose value is not one this can read is kept as NSNull, so that a
 * caller asking for a key finds the key there and not what it is. */
static id MPRISParseEntry(DBusMessageIter *iter)
{
    NSString *key = nil;
    id value = nil;

    DBusMessageIter field;
    dbus_message_iter_recurse(iter, &field);

    if (dbus_message_iter_get_arg_type(&field) == DBUS_TYPE_STRING) {
        const char *rawKey = NULL;
        dbus_message_iter_get_basic(&field, &rawKey);
        if (rawKey != NULL) key = [NSString stringWithUTF8String:rawKey];
    }
    if (dbus_message_iter_next(&field)) {
        value = MPRISParseValue(&field);
    }

    if (key == nil) return value;
    return [NSDictionary dictionaryWithObject:(value ?: [NSNull null]) forKey:key];
}

static id MPRISParseContainer(DBusMessageIter *iter)
{
    switch (dbus_message_iter_get_arg_type(iter)) {
        case DBUS_TYPE_DICT_ENTRY:
            return MPRISParseEntry(iter);

        case DBUS_TYPE_ARRAY: {
            DBusMessageIter element;
            dbus_message_iter_recurse(iter, &element);
            switch (dbus_message_iter_get_arg_type(&element)) {
                case DBUS_TYPE_STRING: {
                    NSMutableArray *strings = [NSMutableArray array];
                    while (dbus_message_iter_get_arg_type(&element) == DBUS_TYPE_STRING) {
                        const char *raw = NULL;
                        dbus_message_iter_get_basic(&element, &raw);
                        if (raw != NULL) {
                            [strings addObject:[NSString stringWithUTF8String:raw]];
                        }
                        if (!dbus_message_iter_next(&element)) break;
                    }
                    return strings;
                }
                case DBUS_TYPE_DICT_ENTRY: {
                    NSMutableDictionary *nested = [NSMutableDictionary dictionary];
                    while (dbus_message_iter_get_arg_type(&element) == DBUS_TYPE_DICT_ENTRY) {
                        id parsed = MPRISParseEntry(&element);
                        if ([parsed isKindOfClass:[NSDictionary class]]) {
                            [nested addEntriesFromDictionary:(NSDictionary *)parsed];
                        }
                        if (!dbus_message_iter_next(&element)) break;
                    }
                    return nested;
                }
                default:
                    /* An array of numbers, of structs, of anything else:
                       nothing here is one, and its contents are not read. */
                    return nil;
            }
        }
        default:
            return nil;
    }
}

static id MPRISParseValue(DBusMessageIter *iter)
{
    switch (dbus_message_iter_get_arg_type(iter)) {
        case DBUS_TYPE_STRING: {
            const char *raw = NULL;
            dbus_message_iter_get_basic(iter, &raw);
            return (raw != NULL) ? [NSString stringWithUTF8String:raw] : @"";
        }
        case DBUS_TYPE_BOOLEAN: {
            dbus_bool_t value = FALSE;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithBool:(value != FALSE)];
        }
        case DBUS_TYPE_BYTE: {
            unsigned char value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithUnsignedChar:value];
        }
        case DBUS_TYPE_INT16: {
            dbus_int16_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithInt:(int)value];
        }
        case DBUS_TYPE_UINT16: {
            dbus_uint16_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithUnsignedInt:(unsigned int)value];
        }
        case DBUS_TYPE_INT32: {
            dbus_int32_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithInt:(int)value];
        }
        case DBUS_TYPE_UINT32: {
            dbus_uint32_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithUnsignedLongLong:(unsigned long long)value];
        }
        case DBUS_TYPE_INT64: {
            dbus_int64_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithLongLong:(long long)value];
        }
        case DBUS_TYPE_UINT64: {
            dbus_uint64_t value = 0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithUnsignedLongLong:(unsigned long long)value];
        }
        case DBUS_TYPE_DOUBLE: {
            double value = 0.0;
            dbus_message_iter_get_basic(iter, &value);
            return [NSNumber numberWithDouble:value];
        }
        case DBUS_TYPE_VARIANT: {
            DBusMessageIter variant;
            dbus_message_iter_recurse(iter, &variant);
            return MPRISParseValue(&variant);
        }
        case DBUS_TYPE_ARRAY:
        case DBUS_TYPE_DICT_ENTRY:
            return MPRISParseContainer(iter);
        default:
            return nil;
    }
}

/* The a{sv} an array iterator is positioned on, as a dictionary. */
static NSDictionary *MPRISParseDictionary(DBusMessageIter *array)
{
    NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
    DBusMessageIter entry;
    if (dbus_message_iter_get_arg_type(array) != DBUS_TYPE_ARRAY) return parsed;

    dbus_message_iter_recurse(array, &entry);
    while (dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_DICT_ENTRY) {
        id one = MPRISParseEntry(&entry);
        if ([one isKindOfClass:[NSDictionary class]]) {
            [parsed addEntriesFromDictionary:(NSDictionary *)one];
        }
        if (!dbus_message_iter_next(&entry)) break;
    }
    return parsed;
}

static NSString *MPRISStringValue(NSDictionary *properties, NSString *key)
{
    id value = [properties objectForKey:key];
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

/* xesam:artist is a list, and a track usually has one name in it. */
static NSString *MPRISArtistFromMetadata(NSDictionary *metadata)
{
    id artists = [metadata objectForKey:@"xesam:artist"];
    if ([artists isKindOfClass:[NSString class]]) return (NSString *)artists;
    if (![artists isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray *names = [NSMutableArray array];
    for (id artist in (NSArray *)artists) {
        if ([artist isKindOfClass:[NSString class]]) {
            [names addObject:(NSString *)artist];
        }
    }
    if ([names count] == 0) return nil;
    return [names componentsJoinedByString:@", "];
}

@interface MPRISMediaController ()
{
    NSThread *_worker;
    /* Read by the worker on every turn of its loop and written by -stop from
       another thread, so it is a plain word written atomically. */
    volatile BOOL _stopping;
    BOOL _running;
    /* How -stop waits for the worker to be gone: GNUstep's NSThread has no
       -waitUntilExit, and a condition is what a thread that ends on its own
       can be waited for with. */
    NSCondition *_workerEnded;
    BOOL _workerHasEnded;
    int _wakePipe[2];
    NSMutableDictionary<NSString *, NSDictionary *> *_players;
    NSMutableArray<NSArray<NSString *> *> *_commands;
    /* A signal's sender, in its unique form, against the player it belongs
       to.  See -playerBusNameForUniqueName:onConnection:. */
    NSMutableDictionary<NSString *, NSString *> *_uniqueNames;
}

/* Called from the message filter, which runs on the worker, from inside the
   dispatch the bus delivers the signal in.  Nothing that waits for an answer
   may be called from here. */
- (void)handleSignal:(DBusMessage *)message;

/* Both of these run on the main thread: see -reportToMainThread: for why a
   line cannot be printed on the worker. */
- (void)reportToMainThread:(NSString *)message;
- (void)printOnMainThread:(NSString *)message;

@end

/* Every message the worker dispatches passes through here.  A signal is the
   only kind of message this object path is registered for; anything else
   belongs to the connection's own business and is passed on. */
static DBusHandlerResult MPRISMessageFilter(DBusConnection *connection,
                                            DBusMessage *message,
                                            void *user_data)
{
    (void)connection;
    if (user_data == NULL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_SIGNAL) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    MPRISMediaController *controller = (__bridge MPRISMediaController *)user_data;
    [controller handleSignal:message];
    return DBUS_HANDLER_RESULT_HANDLED;
}

@implementation MPRISMediaController

+ (instancetype)sharedController
{
    static MPRISMediaController *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[MPRISMediaController alloc] init];
        }
    }
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _players = [[NSMutableDictionary alloc] init];
        _commands = [[NSMutableArray alloc] init];
        _uniqueNames = [[NSMutableDictionary alloc] init];
        _workerEnded = [[NSCondition alloc] init];
        _wakePipe[0] = -1;
        _wakePipe[1] = -1;
    }
    return self;
}

- (void)dealloc
{
    /* The worker holds this object for as long as it runs, so a controller
       that was started and not stopped is never deallocated. */
    [self stop];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark - Starting and stopping

- (BOOL)start
{
    @synchronized(self) {
        if (_running) return NO;

        if (pipe(_wakePipe) != 0) {
            NSDebugLLog(@"gwcomp", @"MPRIS: no pipe to wake the worker with: %s", strerror(errno));
            _wakePipe[0] = -1;
            _wakePipe[1] = -1;
            return NO;
        }
        for (int i = 0; i < 2; i++) {
            fcntl(_wakePipe[i], F_SETFL, O_NONBLOCK);
            fcntl(_wakePipe[i], F_SETFD, FD_CLOEXEC);
        }

        _stopping = NO;
        _running = YES;
        [_workerEnded lock];
        _workerHasEnded = NO;
        [_workerEnded unlock];
        /* The thread holds the target until it ends, which is what keeps
           this controller - and its bus connection - alive for as long as
           the worker runs. */
        _worker = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(workerMain)
                                            object:nil];
        [_worker setName:@"MPRISMediaController"];
        [_worker start];
        return YES;
    }
}

- (void)stop
{
    NSThread *worker = nil;
    @synchronized(self) {
        if (!_running) return;
        _stopping = YES;
        worker = _worker;
        _worker = nil;
    }

    /* Woken through the pipe rather than left to notice on its own, so that
       -stop does not have to wait for a turn of the worker loop. */
    if (_wakePipe[1] >= 0) {
        char byte = 'w';
        ssize_t written = write(_wakePipe[1], &byte, 1);
        (void)written;
    }
    /* Never called from the worker itself: a thread cannot wait for
       itself.  Nothing in this class calls -stop from the worker. */
    if (worker != nil && ![worker isEqual:[NSThread currentThread]]) {
        [_workerEnded lock];
        while (!_workerHasEnded) {
            [_workerEnded waitUntilDate:[NSDate distantFuture]];
        }
        [_workerEnded unlock];
    }

    @synchronized(self) {
        _running = NO;
    }
    for (int i = 0; i < 2; i++) {
        if (_wakePipe[i] >= 0) {
            close(_wakePipe[i]);
            _wakePipe[i] = -1;
        }
    }
}

#pragma mark - What the main thread asks for

- (NSArray<NSDictionary *> *)players
{
    @synchronized(self) {
        /* Sorted by bus name so that a list of players does not jump around
           between two polls for no reason. */
        return [[_players allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a objectForKey:MPRISPlayerBusNameKey] compare:[b objectForKey:MPRISPlayerBusNameKey]];
        }];
    }
}

- (BOOL)sendCommand:(NSString *)method toPlayerWithBusName:(NSString *)busName
{
    if (![method isKindOfClass:[NSString class]]) return NO;
    if (![busName isKindOfClass:[NSString class]]) return NO;
    if (![busName hasPrefix:@(kPlayerBusPrefix)]) return NO;

    BOOL allowed = NO;
    for (NSUInteger i = 0; i < kAllowedCommandCount; i++) {
        if ([method isEqualToString:kAllowedCommands[i]]) {
            allowed = YES;
            break;
        }
    }
    if (!allowed) return NO;

    @synchronized(self) {
        if ([_players objectForKey:busName] == nil) return NO;
        [_commands addObject:@[method, busName]];
    }
    [self wakeWorker];
    return YES;
}

- (void)requestRefresh
{
    [self wakeWorker];
}

#pragma mark - The worker

- (void)wakeWorker
{
    if (_wakePipe[1] < 0) return;
    char byte = 'w';
    ssize_t written = write(_wakePipe[1], &byte, 1);
    (void)written;   /* a full pipe already means the worker has work */
}

- (void)drainWakePipe
{
    char buffer[64];
    while (read(_wakePipe[0], buffer, sizeof(buffer)) > 0) {
        /* read it all; the pipe is only a doorbell */
    }
}

/* Waits for the worker to be woken, or for `milliseconds` to pass.  Answers
   YES when it was woken. */
- (BOOL)waitForWakeup:(int)milliseconds
{
    if (_wakePipe[0] < 0) return NO;

    struct timeval timeout;
    timeout.tv_sec = milliseconds / 1000;
    timeout.tv_usec = (milliseconds % 1000) * 1000;

    while (!_stopping) {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(_wakePipe[0], &readable);

        int ready = select(_wakePipe[0] + 1, &readable, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (ready == 0) return NO;   // the wait ran out

        [self drainWakePipe];
        return YES;
    }
    return NO;
}

- (void)workerMain
{
    @autoreleasepool {
        /* A connection this object owns may be used from this thread while
           Menu's own connection is used from the main thread, so libdbus
           must know there is more than one thread in the process. */
        dbus_threads_init_default();

        while (!_stopping) {
            DBusConnection *connection = [self openBusConnection];
            if (connection == NULL) {
                [self busWentAway];
                /* Wait for the bus to come back, or to be woken: a bus that
                   is restarted returns on its own a moment later. */
                [self waitForWakeup:kReconnectDelayMS];
                continue;
            }
            [self runBusLoopOnConnection:connection];
            [self closeBusConnection:connection];
        }
    }

    [_workerEnded lock];
    _workerHasEnded = YES;
    [_workerEnded broadcast];
    [_workerEnded unlock];
}

- (DBusConnection *)openBusConnection
{
    DBusError error;
    dbus_error_init(&error);
    DBusConnection *connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
    if (connection == NULL) {
        /* Every report from here is handed to the main thread to be
           printed, never printed here.  A GNUstep log line is stamped with
           the time, and asking for the time takes NSTimeZone's zone_mutex,
           which is held while NSTimeZone reads the local zone back out of
           NSUserDefaults - so a log line on this worker takes the time zone
           lock and then the defaults lock.  The main thread, first touching
           NSConnection (and through it NSUserDefaults) at the very moment
           this hub starts, holds the defaults lock and then wants the time
           zone lock.  Two threads, two locks, opposite order: a deadlock,
           and one that hangs Menu on its own menu bar before it has drawn
           anything.  The text is therefore built here and printed there. */
        if (dbus_error_is_set(&error)) {
            [self reportToMainThread:[NSString stringWithFormat:@"MPRIS: no session bus: %s",
                                      error.message]];
            dbus_error_free(&error);
        } else {
            [self reportToMainThread:@"MPRIS: no session bus"];
        }
        return NULL;
    }

    /* A bus that goes away must not take Menu down with it: the connection
       reports the loss and this object looks for the bus again. */
    dbus_connection_set_exit_on_disconnect(connection, FALSE);

    /* Two signals, and nothing else off the bus: a player that appears or
       goes away, and a player that says what it is now doing.  Both are
       matched on the bus rather than watched for, so a private connection
       sees nothing else at all.

       A match rule the bus refuses is not a detail to be swallowed: without
       it the connection receives no signal at all, and the extra would sit
       on the state of the last poll and never hear a player start.  So each
       rule is checked, and a refusal is said out loud. */
    static const char *const kMatchRules[] = {
        /* Not arg0prefix: dbus-daemon accepts 'arg0path' and
           'arg0namespace', not a prefix of the plain string arg0, and
           refuses a rule it does not understand outright.  Matching every
           NameOwnerChanged and throwing the names away in the handler is
           what that costs, and it is the only spelling that works. */
        "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
        "type='signal',interface='org.freedesktop.DBus.Properties',"
        "member='PropertiesChanged',arg0='org.mpris.MediaPlayer2.Player'"
    };
    for (size_t i = 0; i < sizeof(kMatchRules) / sizeof(kMatchRules[0]); i++) {
        dbus_error_init(&error);
        dbus_bus_add_match(connection, kMatchRules[i], &error);
        if (dbus_error_is_set(&error)) {
            /* Printed on the main thread: see -openBusConnection. */
            [self reportToMainThread:[NSString stringWithFormat:
                @"MPRIS: the bus refused a match rule (%s): %s", kMatchRules[i], error.message]];
            dbus_error_free(&error);
        }
    }

    dbus_connection_add_filter(connection, MPRISMessageFilter, (__bridge void *)self, NULL);
    return connection;
}

- (void)closeBusConnection:(DBusConnection *)connection
{
    /* The same user data it was added with: libdbus matches the function
       and the data together, and removing with a different data is a filter
       that was never added. */
    dbus_connection_remove_filter(connection, MPRISMessageFilter, (__bridge void *)self);
    dbus_connection_close(connection);
    dbus_connection_unref(connection);
}

/* Runs until the worker is stopped or the bus is lost.  Only ever called on
   the worker.

   libdbus does not hand out the file descriptor of a connection, so the bus
   cannot be waited on together with the pipe that wakes the worker; it is
   read without waiting instead, once per turn of the loop.  The turn is
   short - a quarter of a second of quiet ends it, and anything that arrives
   is read at once - and a queued command ends it early, so a command waits
   for nothing. */
- (void)runBusLoopOnConnection:(DBusConnection *)connection
{
    [self refreshPlayersOnConnection:connection];

    NSTimeInterval sinceRefresh = 0.0;
    while (!_stopping) {
        [self sendQueuedCommandsOnConnection:connection];
        [self waitForWakeup:kIdleTimeoutMS];
        if (![self dispatchPendingMessagesOnConnection:connection]) {
            return;   // the bus is gone; the caller looks for it again
        }

        /* The signals are what make this quick: a player that starts, stops
           or quits says so, and the state is corrected at once.  They are
           not what makes it correct, though.  A match rule the bus refuses,
           a player that starts before this connected, a connection that
           comes up before the rule is in place - each of those leaves a
           player the signals never mention, and the extra would show it as
           absent, or as doing something it stopped doing, for as long as
           Menu runs.  So the bus is read over again from time to time, and
           the signals only decide how soon. */
        sinceRefresh += kIdleTimeoutMS / 1000.0;
        if (sinceRefresh >= kFullRefreshSeconds) {
            sinceRefresh = 0.0;
            [self refreshPlayersOnConnection:connection];
        }
    }
}

/* Reads what arrived and hands it to the filter, without waiting for more.
   Answers NO when the connection is no longer usable. */
- (BOOL)dispatchPendingMessagesOnConnection:(DBusConnection *)connection
{
    if (!dbus_connection_get_is_connected(connection)) return NO;

    dbus_connection_read_write(connection, 0);
    while (dbus_connection_get_dispatch_status(connection) == DBUS_DISPATCH_DATA_REMAINS) {
        dbus_connection_dispatch(connection);
    }
    /* A bus that went away leaves the connection open but not connected;
       asking it anything from here on would block. */
    return dbus_connection_get_is_connected(connection) ? YES : NO;
}

/* The state of the players is dropped when the bus goes: nothing can be
   said about a player that cannot be asked any more, and the extra would
   rather show nothing than show a player that is not there. */
- (void)busWentAway
{
    BOOL hadPlayers = NO;
    @synchronized(self) {
        hadPlayers = ([_players count] > 0);
        [_players removeAllObjects];
    }
    if (hadPlayers) [self postChanged];
}

#pragma mark - Talking to a player

- (NSArray<NSString *> *)listPlayerBusNamesOnConnection:(DBusConnection *)connection
{
    /* The bus itself is the destination, its own object the path, and the
       interface it answers on the same name again. */
    DBusMessage *message = dbus_message_new_method_call(kDBusInterface,
                                                       "/org/freedesktop/DBus",
                                                       kDBusInterface,
                                                       "ListNames");
    if (message == NULL) return @[];

    DBusMessage *reply = dbus_connection_send_with_reply_and_block(connection, message,
                                                                   kCallTimeoutMS, NULL);
    dbus_message_unref(message);
    if (reply == NULL) return @[];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    DBusMessageIter iter;
    if (dbus_message_iter_init(reply, &iter) &&
        dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_ARRAY) {
        DBusMessageIter element;
        dbus_message_iter_recurse(&iter, &element);
        while (dbus_message_iter_get_arg_type(&element) == DBUS_TYPE_STRING) {
            const char *raw = NULL;
            dbus_message_iter_get_basic(&element, &raw);
            if (raw != NULL) {
                NSString *name = [NSString stringWithUTF8String:raw];
                /* The prefix without its trailing dot is the media player
                   root object itself, which is not a player. */
                if ([name hasPrefix:@(kPlayerBusPrefix)] && [name length] > strlen(kPlayerBusPrefix)) {
                    [names addObject:name];
                }
            }
            if (!dbus_message_iter_next(&element)) break;
        }
    }
    dbus_message_unref(reply);
    return names;
}

- (NSDictionary *)propertiesOfInterface:(const char *)interface
                              ofPlayer:(NSString *)busName
                           onConnection:(DBusConnection *)connection
{
    DBusMessage *message =
        dbus_message_new_method_call(busName.UTF8String, kPlayerObjectPath,
                                     kPropertiesInterface, "GetAll");
    if (message == NULL) return nil;

    const char *rawInterface = interface;
    if (!dbus_message_append_args(message, DBUS_TYPE_STRING, &rawInterface, DBUS_TYPE_INVALID)) {
        dbus_message_unref(message);
        return nil;
    }

    DBusMessage *reply = dbus_connection_send_with_reply_and_block(connection, message,
                                                                   kCallTimeoutMS, NULL);
    dbus_message_unref(message);
    if (reply == NULL) return nil;

    NSDictionary *properties = nil;
    DBusMessageIter iter;
    if (dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_METHOD_RETURN &&
        dbus_message_iter_init(reply, &iter)) {
        properties = MPRISParseDictionary(&iter);
    }
    dbus_message_unref(reply);
    return properties;
}

/* Asks the bus which unique name each of these players is reached under, so
 * that a signal stamped with a unique name can be attributed to the player
 * that sent it.  A player that does not answer is left out rather than
 * guessed at, and its signals are then ignored until the next poll, which
 * is the same answer the rest of the state gives while it is unreachable. */
- (void)refreshUniqueNamesOnConnection:(DBusConnection *)connection
                        forBusNames:(NSArray<NSString *> *)busNames
{
    NSMutableDictionary<NSString *, NSString *> *uniqueNames =
        [NSMutableDictionary dictionaryWithCapacity:[busNames count]];

    for (NSString *busName in busNames) {
        if (_stopping) return;

        DBusMessage *message = dbus_message_new_method_call(kDBusInterface,
                                                           "/org/freedesktop/DBus",
                                                           kDBusInterface,
                                                           "GetNameOwner");
        if (message == NULL) continue;
        const char *rawBusName = [busName UTF8String];
        if (!dbus_message_append_args(message, DBUS_TYPE_STRING, &rawBusName, DBUS_TYPE_INVALID)) {
            dbus_message_unref(message);
            continue;
        }

        DBusMessage *reply = dbus_connection_send_with_reply_and_block(connection, message,
                                                                       kCallTimeoutMS, NULL);
        dbus_message_unref(message);
        if (reply == NULL) continue;

        DBusMessageIter iter;
        if (dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_METHOD_RETURN &&
            dbus_message_iter_init(reply, &iter) &&
            dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
            const char *rawUnique = NULL;
            dbus_message_iter_get_basic(&iter, &rawUnique);
            if (rawUnique != NULL) {
                [uniqueNames setObject:busName
                                forKey:[NSString stringWithUTF8String:rawUnique]];
            }
        }
        dbus_message_unref(reply);
    }

    @synchronized(self) {
        _uniqueNames = uniqueNames;
    }
}

- (void)refreshPlayersOnConnection:(DBusConnection *)connection
{
    if (_stopping) return;

    NSArray<NSString *> *busNames = [self listPlayerBusNamesOnConnection:connection];
    [self refreshUniqueNamesOnConnection:connection forBusNames:busNames];
    NSMutableDictionary<NSString *, NSDictionary *> *found = [NSMutableDictionary dictionary];

    for (NSString *busName in busNames) {
        if (_stopping) return;

        NSDictionary *rootProperties = [self propertiesOfInterface:kRootInterface
                                                           ofPlayer:busName
                                                        onConnection:connection];
        NSDictionary *playerProperties = [self propertiesOfInterface:kPlayerInterface
                                                            ofPlayer:busName
                                                         onConnection:connection];
        /* A player that answers neither the root nor the Player interface
           is not one this can steer, whatever its name says. */
        if (rootProperties == nil && playerProperties == nil) continue;

        NSString *identity = MPRISStringValue(rootProperties, @"Identity");
        NSString *status = MPRISStringValue(playerProperties, @"PlaybackStatus");
        id metadata = [playerProperties objectForKey:@"Metadata"];
        NSDictionary *track = [metadata isKindOfClass:[NSDictionary class]] ? (NSDictionary *)metadata : nil;

        [found setObject:@{
            MPRISPlayerBusNameKey: busName,
            /* A player that does not name itself is named after its bus
               name, which at least is a name the user can recognise. */
            MPRISPlayerIdentityKey: identity ?: [busName substringFromIndex:strlen(kPlayerBusPrefix)],
            MPRISPlayerStatusKey: status ?: @"Stopped",
            MPRISPlayerTitleKey: MPRISStringValue(track, @"xesam:title") ?: @"",
            MPRISPlayerArtistKey: MPRISArtistFromMetadata(track) ?: @"",
        } forKey:busName];
    }

    BOOL changed = NO;
    @synchronized(self) {
        if (![_players isEqualToDictionary:found]) {
            _players = found;
            changed = YES;
        }
    }
    if (changed) [self postChanged];
}

- (void)sendQueuedCommandsOnConnection:(DBusConnection *)connection
{
    NSArray<NSArray<NSString *> *> *pending = nil;
    @synchronized(self) {
        if ([_commands count] == 0) return;
        pending = [_commands copy];
        [_commands removeAllObjects];
    }

    for (NSArray<NSString *> *command in pending) {
        DBusMessage *message = dbus_message_new_method_call(command[1].UTF8String,
                                                           kPlayerObjectPath,
                                                           kPlayerInterface,
                                                           command[0].UTF8String);
        if (message == NULL) continue;
        /* Sent without waiting for an answer: a player answers nothing to
           these, and waiting for one anyway would hold up every command
           behind it.  A player that has just quit drops the message. */
        dbus_connection_send(connection, message, NULL);
        dbus_message_unref(message);
    }
    dbus_connection_flush(connection);
}

#pragma mark - Signals

- (void)handleSignal:(DBusMessage *)message
{
    const char *interface = dbus_message_get_interface(message);
    const char *member = dbus_message_get_member(message);
    if (interface == NULL || member == NULL) return;

    if (strcmp(interface, kDBusInterface) == 0 && strcmp(member, "NameOwnerChanged") == 0) {
        [self handleNameOwnerChanged:message];
    } else if (strcmp(interface, kPropertiesInterface) == 0 && strcmp(member, "PropertiesChanged") == 0) {
        [self handlePropertiesChanged:message];
    }
}

/* The name a match rule is written with, and the name a signal is stamped
 * with, are two different things: a player holds a well-known name of its
 * own, org.mpris.MediaPlayer2.<instance>, and a unique name of the form
 * :1.7 that the bus hands out.  Rules can only be written with the
 * well-known one, while every signal arrives stamped with the unique one, so
 * a signal has to be resolved back to its player before it can be acted on.
 *
 * The two are tied together while the bus is being read over, in
 * -refreshUniqueNamesOnConnection:, and this only ever looks the answer up.
 * That is not a shortcut: a signal is handled from inside the dispatch the
 * bus delivers it in, and a call that waits for an answer cannot be made
 * from in there - it would be the same connection, waiting on itself.  A
 * name that is not in the table is a player that has just started, and the
 * answer to that is a look at the bus again, not a question asked here. */
- (NSString *)playerBusNameForUniqueName:(NSString *)uniqueName
{
    if ([uniqueName length] == 0) return nil;
    @synchronized(self) {
        return [_uniqueNames objectForKey:uniqueName];
    }
}

/* A name on the bus changed hands, or came into being, or went away.  Only
   a player name is of any interest here, and the signal carries both forms
   of the name: the first argument is the well-known name if the name is
   well-known and the unique name otherwise, so a player appears twice - once
   for each - and either is enough to notice it by. */
- (void)handleNameOwnerChanged:(DBusMessage *)message
{
    DBusMessageIter iter;
    if (!dbus_message_iter_init(message, &iter)) return;
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) return;

    const char *rawName = NULL;
    dbus_message_iter_get_basic(&iter, &rawName);
    if (rawName == NULL) return;

    NSString *name = [NSString stringWithUTF8String:rawName];
    if (![name hasPrefix:@(kPlayerBusPrefix)]) return;
    [self requestRefresh];
}

- (void)handlePropertiesChanged:(DBusMessage *)message
{
    const char *sender = dbus_message_get_sender(message);
    if (sender == NULL) return;
    NSString *busName = [self playerBusNameForUniqueName:[NSString stringWithUTF8String:sender]];
    if (busName == nil) {
        /* A signal from a player that was not there at the last poll, or
           from something that is not a player.  A look at the bus sorts out
           which, and this is the only thing that may be done about a signal
           from in here - see -playerBusNameForUniqueName. */
        [self requestRefresh];
        return;
    }

    /* The signal is (interface, changed, invalidated).  Only the Player
       interface carries what the extra shows, and only the keys that are
       there are read: a player that changes its volume, or its position,
       says so in the same signal as the ones this cares about. */
    DBusMessageIter iter;
    if (!dbus_message_iter_init(message, &iter)) return;
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) return;

    const char *rawInterface = NULL;
    dbus_message_iter_get_basic(&iter, &rawInterface);
    if (rawInterface == NULL || strcmp(rawInterface, kPlayerInterface) != 0) return;
    if (!dbus_message_iter_next(&iter)) return;
    if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_ARRAY) return;

    [self applyChangedProperties:MPRISParseDictionary(&iter) toPlayerWithBusName:busName];
}

- (void)applyChangedProperties:(NSDictionary *)changed toPlayerWithBusName:(NSString *)busName
{
    if ([changed count] == 0) return;

    BOOL changedSomething = NO;
    BOOL unknownPlayer = NO;
    @synchronized(self) {
        NSDictionary *entry = [_players objectForKey:busName];
        if (entry == nil) {
            /* A player this has not seen yet, or one that has come back
               under a name it had before: only a look at the bus can say
               which, and what it is playing. */
            unknownPlayer = YES;
        } else {
            NSMutableDictionary *updated = [entry mutableCopy];
            NSString *status = MPRISStringValue(changed, @"PlaybackStatus");
            if (status != nil) {
                [updated setObject:status forKey:MPRISPlayerStatusKey];
            }
            id metadata = [changed objectForKey:@"Metadata"];
            if ([metadata isKindOfClass:[NSDictionary class]]) {
                NSDictionary *track = (NSDictionary *)metadata;
                [updated setObject:(MPRISStringValue(track, @"xesam:title") ?: @"")
                            forKey:MPRISPlayerTitleKey];
                [updated setObject:(MPRISArtistFromMetadata(track) ?: @"")
                            forKey:MPRISPlayerArtistKey];
            }
            if (![updated isEqualToDictionary:entry]) {
                [_players setObject:updated forKey:busName];
                changedSomething = YES;
            }
        }
    }

    if (unknownPlayer) {
        [self requestRefresh];
    } else if (changedSomething) {
        [self postChanged];
    }
}

#pragma mark - Telling the rest of Menu

/* Hands a line to the main thread to be printed, and returns at once.  A
   worker that printed for itself would stamp the line with the time, and
   that is the deadlock described in -openBusConnection: NSTimeZone's zone
   mutex taken first, NSUserDefaults' lock second, while the main thread
   takes them the other way round while starting up.  The line is built here
   - building a string touches nothing that is locked - and only the
   timestamping is left to the thread that owns those locks. */
- (void)reportToMainThread:(NSString *)message
{
    [self performSelectorOnMainThread:@selector(printOnMainThread:)
                           withObject:message
                        waitUntilDone:NO];
}

- (void)printOnMainThread:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"%@", message);
}

/* The notification is delivered on the main thread, because that is where
   it is observed from: the menu bar may only be touched there.  The state
   itself is already in place by the time this is asked for, so a listener
   that is late still reads the truth. */
- (void)postChanged
{
    [self performSelectorOnMainThread:@selector(deliverChangedNotification)
                           withObject:nil
                        waitUntilDone:NO];
}

- (void)deliverChangedNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:MPRISMediaControllerChangedNotification
                                                        object:self];
}

@end
