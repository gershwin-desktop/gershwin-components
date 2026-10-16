/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_MPRISMediaController.m - MPRISMediaController against a player that is
 * really there.
 *
 * The controller is the one part of the media hub that speaks D-Bus, and
 * nearly everything that could be wrong with it is in the bus plumbing: the
 * names it looks for, the a{sv} it parses, the PropertiesChanged it acts
 * on, the commands it sends, and what it does when a player quits.  None of
 * that can be checked without a bus and a player on it, so this test starts
 * both: a dbus-daemon of its own, and a fake MPRIS2 player on it, which is
 * as much of the real thing as a test can stand up.
 *
 * Headless: no display, no sound, no window, and no bus of the session -
 * the daemon this starts is the only bus the test can see.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "MPRISMediaController.h"

#include <dbus/dbus.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const kPlayerBusName = "org.mpris.MediaPlayer2.faketest";
static const char *const kPlayerPath = "/org/mpris/MediaPlayer2";
static const char *const kPlayerInterface = "org.mpris.MediaPlayer2.Player";
static const char *const kRootInterface = "org.mpris.MediaPlayer2";
static const char *const kPropertiesInterface = "org.freedesktop.DBus.Properties";

#pragma mark - The state the fake player reports

/* Written by the player's own dispatch thread and read by the test, so it
   is held under this lock. */
static NSLock *stateLock = nil;
static NSString *playerStatus = nil;
static NSString *playerTitle = nil;
static NSString *playerArtist = nil;
static NSUInteger playCount = 0, pauseCount = 0, playPauseCount = 0;
static NSUInteger stopCount = 0, nextCount = 0, previousCount = 0;

static NSUInteger CommandCount(void)
{
    NSUInteger total = 0;
    [stateLock lock];
    total = playCount + pauseCount + playPauseCount + stopCount + nextCount + previousCount;
    [stateLock unlock];
    return total;
}

static NSUInteger CounterOf(int which)
{
    NSUInteger value = 0;
    [stateLock lock];
    switch (which) {
        case 0: value = playCount; break;
        case 1: value = pauseCount; break;
        case 2: value = playPauseCount; break;
        case 3: value = stopCount; break;
        case 4: value = nextCount; break;
        default: value = previousCount; break;
    }
    [stateLock unlock];
    return value;
}

static NSString *StatusOf(void)
{
    NSString *status = nil;
    [stateLock lock];
    status = [[playerStatus copy] autorelease];
    [stateLock unlock];
    return status;
}

#pragma mark - Building what a player sends

/* One "key": string of a dictionary of variants. */
static void AppendStringProperty(DBusMessageIter *dict, const char *key, const char *value)
{
    DBusMessageIter entry, variant;
    const char *rawKey = key;
    const char *rawValue = value;

    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &rawKey);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &rawValue);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

/* xesam:artist is a list of names, so Metadata is the one property that has
   to be read deeper than a string: the parse in the controller walks into
   the list, and a title and an artist together are the two shapes that
   break it if either is misread. */
static void AppendMetadataProperty(DBusMessageIter *dict)
{
    DBusMessageIter entry, variant, metadata, item, inner, list;
    const char *rawKey = "Metadata";
    const char *titleKey = "xesam:title";
    const char *artistKey = "xesam:artist";
    NSString *heldTitle = nil;
    NSString *heldArtist = nil;

    [stateLock lock];
    heldTitle = [[playerTitle copy] autorelease];
    heldArtist = [[playerArtist copy] autorelease];
    [stateLock unlock];

    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &rawKey);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "a{sv}", &variant);
    dbus_message_iter_open_container(&variant, DBUS_TYPE_ARRAY, "{sv}", &metadata);

    if (heldTitle != nil) {
        const char *rawTitle = [heldTitle UTF8String];
        dbus_message_iter_open_container(&metadata, DBUS_TYPE_DICT_ENTRY, NULL, &item);
        dbus_message_iter_append_basic(&item, DBUS_TYPE_STRING, &titleKey);
        dbus_message_iter_open_container(&item, DBUS_TYPE_VARIANT, "s", &inner);
        dbus_message_iter_append_basic(&inner, DBUS_TYPE_STRING, &rawTitle);
        dbus_message_iter_close_container(&item, &inner);
        dbus_message_iter_close_container(&metadata, &item);
    }
    if (heldArtist != nil) {
        const char *rawArtist = [heldArtist UTF8String];
        dbus_message_iter_open_container(&metadata, DBUS_TYPE_DICT_ENTRY, NULL, &item);
        dbus_message_iter_append_basic(&item, DBUS_TYPE_STRING, &artistKey);
        dbus_message_iter_open_container(&item, DBUS_TYPE_VARIANT, "as", &inner);
        /* The variant holds the array and the array holds the names: the
           list is what makes this property a list, so it is built rather
           than faked with one name. */
        dbus_message_iter_open_container(&inner, DBUS_TYPE_ARRAY, "s", &list);
        dbus_message_iter_append_basic(&list, DBUS_TYPE_STRING, &rawArtist);
        dbus_message_iter_close_container(&inner, &list);
        dbus_message_iter_close_container(&item, &inner);
        dbus_message_iter_close_container(&metadata, &item);
    }

    dbus_message_iter_close_container(&variant, &metadata);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

/* What a player does when it starts or stops playing: say so on the bus
   with a PropertiesChanged, which is how a client hears about it without
   having to ask again. */
static void AnnouncePlaybackStatus(DBusConnection *connection, NSString *newStatus)
{
    [stateLock lock];
    [playerStatus release];
    playerStatus = [newStatus copy];
    [stateLock unlock];

    if (connection == NULL) return;

    DBusMessage *signal = dbus_message_new_signal(kPlayerPath,
                                                  kPropertiesInterface,
                                                  "PropertiesChanged");
    if (signal == NULL) return;

    DBusMessageIter iter, changed, invalidated;
    const char *interface = kPlayerInterface;
    dbus_message_iter_init_append(signal, &iter);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &interface);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &changed);
    AppendStringProperty(&changed, "PlaybackStatus", [newStatus UTF8String]);
    dbus_message_iter_close_container(&iter, &changed);
    /* And the list of properties that are no longer valid at all, which a
       player is allowed to send and a client has to survive. */
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &invalidated);
    dbus_message_iter_close_container(&iter, &invalidated);

    dbus_connection_send(connection, signal, NULL);
    dbus_connection_flush(connection);
    dbus_message_unref(signal);
}

#pragma mark - The player

/* Its dispatch loop, so that a command sent to it is answered while the
   test is busy waiting for something else. */
typedef struct {
    DBusConnection *connection;
    pthread_t thread;
    volatile int running;
} FakeRunLoop;

static FakeRunLoop *theRunLoop = NULL;

static DBusHandlerResult FakeObjectMessage(DBusConnection *connection,
                                           DBusMessage *message,
                                           void *user_data)
{
    (void)user_data;

    const char *interface = dbus_message_get_interface(message);
    const char *member = dbus_message_get_member(message);
    if (interface == NULL || member == NULL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (strcmp(interface, kPlayerInterface) == 0) {
        if (strcmp(member, "Play") == 0) {
            [stateLock lock]; playCount++; [stateLock unlock];
            AnnouncePlaybackStatus(connection, @"Playing");
        } else if (strcmp(member, "Pause") == 0) {
            [stateLock lock]; pauseCount++; [stateLock unlock];
            AnnouncePlaybackStatus(connection, @"Paused");
        } else if (strcmp(member, "PlayPause") == 0) {
            NSString *was = nil;
            [stateLock lock];
            playPauseCount++;
            was = [[playerStatus copy] autorelease];
            [stateLock unlock];
            AnnouncePlaybackStatus(connection,
                                  [was isEqualToString:@"Playing"] ? @"Paused" : @"Playing");
        } else if (strcmp(member, "Stop") == 0) {
            [stateLock lock]; stopCount++; [stateLock unlock];
            AnnouncePlaybackStatus(connection, @"Stopped");
        } else if (strcmp(member, "Next") == 0) {
            [stateLock lock]; nextCount++; [stateLock unlock];
        } else if (strcmp(member, "Previous") == 0) {
            [stateLock lock]; previousCount++; [stateLock unlock];
        } else {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }
        /* Every MPRIS method returns nothing, so the answer is an empty
           reply - which this player does send, because a client that waits
           for one must not be left waiting. */
        DBusMessage *reply = dbus_message_new_method_return(message);
        if (reply != NULL) {
            dbus_connection_send(connection, reply, NULL);
            dbus_message_unref(reply);
        }
        dbus_connection_flush(connection);
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    /* Properties.GetAll, which is how a client reads the state. */
    if (strcmp(interface, kPropertiesInterface) == 0 && strcmp(member, "GetAll") == 0) {
        DBusMessageIter iter;
        if (!dbus_message_iter_init(message, &iter)) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        }
        const char *wanted = NULL;
        dbus_message_iter_get_basic(&iter, &wanted);
        if (wanted == NULL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

        DBusMessage *reply = dbus_message_new_method_return(message);
        if (reply == NULL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

        /* The a{sv} the reply is, opened into an iterator of its own: the
           container and the position inside it are two things, and reusing
           one for both closes the container under itself. */
        DBusMessageIter out, dict;
        dbus_message_iter_init_append(reply, &out);
        dbus_message_iter_open_container(&out, DBUS_TYPE_ARRAY, "{sv}", &dict);
        if (strcmp(wanted, kRootInterface) == 0) {
            AppendStringProperty(&dict, "Identity", "Fake Test Player");
        } else if (strcmp(wanted, kPlayerInterface) == 0) {
            AppendStringProperty(&dict, "PlaybackStatus", [StatusOf() UTF8String]);
            AppendMetadataProperty(&dict);
        }
        dbus_message_iter_close_container(&out, &dict);

        dbus_connection_send(connection, reply, NULL);
        dbus_message_unref(reply);
        dbus_connection_flush(connection);
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static DBusObjectPathVTable fakeObjectVTable = {
    NULL,                 /* unregister_function */
    FakeObjectMessage     /* message_function */
};

static void *FakePlayerThread(void *context)
{
    FakeRunLoop *loop = (FakeRunLoop *)context;
    while (loop->running) {
        dbus_connection_read_write(loop->connection, 50);
        while (dbus_connection_get_dispatch_status(loop->connection) == DBUS_DISPATCH_DATA_REMAINS) {
            dbus_connection_dispatch(loop->connection);
        }
    }
    return NULL;
}

/* Takes the bus name and starts answering on it.  Answers NO when it could
   not, which is the test's cue to say so rather than to go on to a case
   that cannot mean anything. */
static BOOL StartFakePlayer(void)
{
    DBusError error;
    dbus_error_init(&error);

    DBusConnection *connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
    if (connection == NULL) {
        if (dbus_error_is_set(&error)) dbus_error_free(&error);
        return NO;
    }
    dbus_connection_set_exit_on_disconnect(connection, FALSE);

    if (dbus_bus_request_name(connection, kPlayerBusName,
                              DBUS_NAME_FLAG_REPLACE_EXISTING |
                              DBUS_NAME_FLAG_ALLOW_REPLACEMENT,
                              &error) != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        if (dbus_error_is_set(&error)) dbus_error_free(&error);
        dbus_connection_unref(connection);
        return NO;
    }
    if (!dbus_connection_register_object_path(connection, kPlayerPath, &fakeObjectVTable, NULL)) {
        dbus_connection_unref(connection);
        return NO;
    }

    FakeRunLoop *loop = (FakeRunLoop *)calloc(1, sizeof(FakeRunLoop));
    if (loop == NULL) {
        dbus_connection_unref(connection);
        return NO;
    }
    loop->connection = connection;
    loop->running = 1;
    theRunLoop = loop;

    if (pthread_create(&loop->thread, NULL, FakePlayerThread, loop) != 0) {
        theRunLoop = NULL;
        free(loop);
        dbus_connection_unref(connection);
        return NO;
    }
    return YES;
}

/* Stops answering and gives the bus name back, which is what a player does
   when it quits: closing the connection gives up every name it held. */
static void StopFakePlayer(void)
{
    FakeRunLoop *loop = theRunLoop;
    if (loop == NULL) return;
    theRunLoop = NULL;

    loop->running = 0;
    pthread_join(loop->thread, NULL);
    dbus_connection_close(loop->connection);
    dbus_connection_unref(loop->connection);
    free(loop);
}

#pragma mark - A bus of our own

/* Starts a dbus-daemon for this test and puts its address in the
   environment, which is where libdbus looks for the session bus.  Answers
   NO when there is no dbus-daemon to be had, so the test can say that
   rather than fail for want of one. */
static BOOL StartPrivateBus(void)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/dbus-daemon"];
    [task setArguments:@[@"--session", @"--print-address", @"--nofork"]];
    NSPipe *out = [NSPipe pipe];
    [task setStandardOutput:out];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return NO;   // no dbus-daemon here
    }

    /* The address is the first line it prints and it prints it at once;
       what follows is the daemon itself, still running, so the read stops
       at the newline rather than at the end of the output. */
    NSMutableData *address = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSData *chunk = [[out fileHandleForReading] availableData];
        if ([chunk length] > 0) {
            [address appendData:chunk];
            if (memchr([address bytes], '\n', [address length]) != NULL) break;
        } else if (![task isRunning]) {
            break;
        }
    }
    if (memchr([address bytes], '\n', [address length]) == NULL) {
        [task terminate];
        return NO;
    }

    NSString *line = [[[NSString alloc] initWithData:address
                                            encoding:NSUTF8StringEncoding] autorelease];
    line = [[[line componentsSeparatedByString:@"\n"] objectAtIndex:0]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([line length] == 0) {
        [task terminate];
        return NO;
    }

    setenv("DBUS_SESSION_BUS_ADDRESS", [line UTF8String], 1);
    return YES;
}

#pragma mark - Waiting

/* Runs the run loop until `test` answers YES or the time runs out.  The run
   loop has to turn because it is what delivers the controller's change
   notification; the state itself is already in place by then. */
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

static NSDictionary *FindPlayer(MPRISMediaController *controller, NSString *busName)
{
    for (NSDictionary *player in [controller players]) {
        if ([[player objectForKey:MPRISPlayerBusNameKey] isEqualToString:busName]) {
            return player;
        }
    }
    return nil;
}

static NSString *StatusOfPlayer(MPRISMediaController *controller, NSString *busName)
{
    return [[FindPlayer(controller, busName) objectForKey:MPRISPlayerStatusKey] autorelease];
}

#pragma mark - The test

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    stateLock = [[NSLock alloc] init];
    playerStatus = [@"Stopped" copy];
    playerTitle = [@"A Test Track" copy];
    playerArtist = [@"A Test Artist" copy];

    if (!StartPrivateBus()) {
        printf("SKIP: no dbus-daemon, so no bus to test the MPRIS controller on\n");
        return 0;
    }
    if (!StartFakePlayer()) {
        printf("SKIP: the fake player could not take its bus name\n");
        return 0;
    }

    /* --- a player on the bus is found, and read --- */
    MPRISMediaController *controller = [[MPRISMediaController alloc] init];
    PASS([controller start], "the controller starts its worker");

    __block NSDictionary *player = nil;
    PASS(WaitFor(5.0, ^BOOL{
        player = FindPlayer(controller, [NSString stringWithUTF8String:kPlayerBusName]);
        return player != nil;
    }), "a player that takes an org.mpris.MediaPlayer2 name is found");

    if (player != nil) {
        PASS_EQUAL([player objectForKey:MPRISPlayerIdentityKey], @"Fake Test Player",
                   "Identity is read off the root interface");
        PASS_EQUAL([player objectForKey:MPRISPlayerStatusKey], @"Stopped",
                   "PlaybackStatus is read off the Player interface");
        PASS_EQUAL([player objectForKey:MPRISPlayerTitleKey], @"A Test Track",
                   "the title is read out of the metadata dictionary");
        PASS_EQUAL([player objectForKey:MPRISPlayerArtistKey], @"A Test Artist",
                   "and the artist out of the list inside it");
    }

    /* --- the transport commands reach the player --- */
    if (player != nil) {
        NSString *busName = [NSString stringWithUTF8String:kPlayerBusName];
        NSUInteger before = 0;

        before = CommandCount();
        PASS([controller sendCommand:@"Play" toPlayerWithBusName:busName],
             "Play is accepted for a player that is there");
        PASS(WaitFor(5.0, ^BOOL{ return CommandCount() > before; }),
             "and the player really receives it over the bus");

        /* The player announced the change, so the state has to follow
           without anything asking again: this is the PropertiesChanged
           path, and the one the play/pause icon depends on. */
        PASS(WaitFor(5.0, ^BOOL{
            return [StatusOfPlayer(controller, busName) isEqualToString:@"Playing"];
        }), "a PropertiesChanged moves the state to Playing with no poll of its own");

        before = CounterOf(2);
        PASS([controller sendCommand:@"PlayPause" toPlayerWithBusName:busName],
             "PlayPause is accepted");
        PASS(WaitFor(5.0, ^BOOL{ return CounterOf(2) > before; }),
             "and reaches the player");
        PASS(WaitFor(5.0, ^BOOL{
            return [StatusOfPlayer(controller, busName) isEqualToString:@"Paused"];
        }), "which pauses it, and the state follows again");

        before = CounterOf(4);
        [controller sendCommand:@"Next" toPlayerWithBusName:busName];
        PASS(WaitFor(5.0, ^BOOL{ return CounterOf(4) > before; }),
             "Next reaches the player too");

        before = CounterOf(5);
        [controller sendCommand:@"Previous" toPlayerWithBusName:busName];
        PASS(WaitFor(5.0, ^BOOL{ return CounterOf(5) > before; }),
             "and Previous");

        before = CounterOf(3);
        [controller sendCommand:@"Stop" toPlayerWithBusName:busName];
        PASS(WaitFor(5.0, ^BOOL{ return CounterOf(3) > before; }),
             "and Stop");
    }

    /* --- what must not be sent --- */
    PASS(![controller sendCommand:@"Raise"
                    toPlayerWithBusName:[NSString stringWithUTF8String:kPlayerBusName]],
         "a method that is not one of the six is refused");
    PASS(![controller sendCommand:@"Play"
                    toPlayerWithBusName:@"org.mpris.MediaPlayer2.nosuchplayer"],
         "a command for a player that is not there is refused");
    PASS(![controller sendCommand:@"Play" toPlayerWithBusName:@"org.freedesktop.DBus"],
         "a command for a bus name that is not a player at all is refused");
    PASS(![controller sendCommand:@"Play" toPlayerWithBusName:nil],
         "and a nil bus name is refused");

    /* --- a player that quits, and one that comes back --- */
    StopFakePlayer();
    PASS(WaitFor(5.0, ^BOOL{
        return FindPlayer(controller, [NSString stringWithUTF8String:kPlayerBusName]) == nil;
    }), "a player that lets go of its bus name disappears from the list");
    PASS([[controller players] count] == 0, "and leaves no player behind");

    PASS(StartFakePlayer(), "a player that starts again takes its name");
    [controller requestRefresh];
    PASS(WaitFor(5.0, ^BOOL{
        return FindPlayer(controller, [NSString stringWithUTF8String:kPlayerBusName]) != nil;
    }), "and is found again");

    [controller stop];
    PASS(YES, "the controller stops without hanging on the bus");
    [controller release];

    StopFakePlayer();
    [playerStatus release];
    [playerTitle release];
    [playerArtist release];
    [stateLock release];
    [pool release];
    return 0;
}
