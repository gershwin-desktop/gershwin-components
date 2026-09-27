/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */

#import "EnergyLidBackend.h"

#if defined(__linux__)
#import <dbus/dbus.h>
#import <string.h>

/* Returns the first executable path that exists, or nil.  Shared by the
 * capability probe and the inhibitor so they never disagree about where
 * systemd-inhibit lives.  Only Linux calls this today (the only platform
 * with a lock this backend can take at all), so it stays inside the same
 * guard rather than sitting unused - with -Werror on this library - on
 * every other platform. */
static NSString *EnergyLidFindExecutable(NSArray<NSString *> *candidates)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}


/* Watches logind's LidClosed property over the system bus.  A private
 * connection and its own thread exist only between -start and -stop, i.e.
 * only while something is actually armed - Menu holds no D-Bus connection
 * open for this feature the rest of the time.
 *
 * A generation counter, not a boolean, guards against the thread from a
 * previous -start still winding down (up to the 500 ms dispatch timeout)
 * when a new -start spins up another one: the old thread's loop condition
 * reads _generation itself and stops as soon as it no longer matches the
 * value it captured at spawn time, so at most one thread's DBusConnection is
 * ever the one a filter callback can fire from at a time. */
static DBusHandlerResult EnergyLidPropertiesChangedFilter(DBusConnection *connection,
                                                           DBusMessage *message,
                                                           void *userData);

@interface EnergyLidEventSourceLinuxDBus : NSObject <EnergyLidEventSource>
@end

@implementation EnergyLidEventSourceLinuxDBus
{
    void (^_handler)(BOOL closed);
    volatile NSUInteger _generation;
}

- (void)setLidStateHandler:(void (^)(BOOL closed))handler
{
    _handler = [handler copy];
}

- (void)start
{
    NSUInteger myGeneration = ++_generation;
    NSThread *thread = [[NSThread alloc] initWithTarget:self
                                                selector:@selector(threadMain:)
                                                  object:@(myGeneration)];
    [thread start];
}

- (void)stop
{
    /* Bumping the generation is the only signal the background thread
     * reads; it notices within one read_write_dispatch timeout. */
    _generation++;
}

- (void)threadMain:(NSNumber *)generationNumber
{
    @autoreleasepool {
        NSUInteger myGeneration = [generationNumber unsignedIntegerValue];
        DBusError err;
        dbus_error_init(&err);

        DBusConnection *conn = dbus_bus_get_private(DBUS_BUS_SYSTEM, &err);
        if (conn == NULL) {
            NSLog(@"EnergyLidBackend: no D-Bus system bus for logind lid events: %s",
                  err.message ? err.message : "unknown error");
            dbus_error_free(&err);
            return;
        }
        dbus_connection_set_exit_on_disconnect(conn, FALSE);

        dbus_bus_add_match(conn,
            "type='signal',interface='org.freedesktop.DBus.Properties',"
            "member='PropertiesChanged',path='/org/freedesktop/login1'",
            &err);
        if (dbus_error_is_set(&err)) {
            NSLog(@"EnergyLidBackend: could not subscribe to logind lid events: %s", err.message);
            dbus_error_free(&err);
            dbus_connection_close(conn);
            dbus_connection_unref(conn);
            return;
        }

        dbus_connection_add_filter(conn, EnergyLidPropertiesChangedFilter,
                                    (__bridge void *)self, NULL);

        while (_generation == myGeneration) {
            /* FALSE means the bus connection died (logind/dbus restarted
             * under us); stop rather than spin on a dead connection. A
             * fresh -arm later gets a fresh connection via a new -start. */
            if (!dbus_connection_read_write_dispatch(conn, 500)) {
                break;
            }
        }

        dbus_connection_remove_filter(conn, EnergyLidPropertiesChangedFilter,
                                       (__bridge void *)self);
        dbus_connection_close(conn);
        dbus_connection_unref(conn);
    }
}

/* Marshals onto the main thread; the armer this feeds is not thread-safe
 * and every other caller (menu building, the toggle action) runs there. */
- (void)deliverLidClosed:(NSNumber *)closedNumber
{
    if (_handler) {
        _handler([closedNumber boolValue]);
    }
}

@end

static DBusHandlerResult EnergyLidPropertiesChangedFilter(DBusConnection *connection,
                                                           DBusMessage *message,
                                                           void *userData)
{
    (void)connection;
    if (!dbus_message_is_signal(message, "org.freedesktop.DBus.Properties", "PropertiesChanged")) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    DBusMessageIter args;
    if (!dbus_message_iter_init(message, &args) ||
        dbus_message_iter_get_arg_type(&args) != DBUS_TYPE_STRING) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    const char *interfaceName = NULL;
    dbus_message_iter_get_basic(&args, &interfaceName);
    if (interfaceName == NULL || strcmp(interfaceName, "org.freedesktop.login1.Manager") != 0) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    if (!dbus_message_iter_next(&args) ||
        dbus_message_iter_get_arg_type(&args) != DBUS_TYPE_ARRAY) {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    DBusMessageIter dictIter;
    dbus_message_iter_recurse(&args, &dictIter);
    while (dbus_message_iter_get_arg_type(&dictIter) == DBUS_TYPE_DICT_ENTRY) {
        DBusMessageIter entry;
        dbus_message_iter_recurse(&dictIter, &entry);

        const char *key = NULL;
        if (dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&entry, &key);
        }
        dbus_message_iter_next(&entry);

        if (key != NULL && strcmp(key, "LidClosed") == 0 &&
            dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT) {
            DBusMessageIter variant;
            dbus_message_iter_recurse(&entry, &variant);
            if (dbus_message_iter_get_arg_type(&variant) == DBUS_TYPE_BOOLEAN) {
                dbus_bool_t closed = FALSE;
                dbus_message_iter_get_basic(&variant, &closed);
                EnergyLidEventSourceLinuxDBus *source =
                    (__bridge EnergyLidEventSourceLinuxDBus *)userData;
                NSNumber *closedNumber = [NSNumber numberWithBool:(closed != FALSE)];
                [source performSelectorOnMainThread:@selector(deliverLidClosed:)
                                          withObject:closedNumber
                                       waitUntilDone:NO];
            }
        }

        dbus_message_iter_next(&dictIter);
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

/* A logind "handle-lid-switch" block-mode lock: while held, logind performs
 * no action at all for a lid-close event (it does not suspend now, and it
 * does not queue the suspend for when the lock is released later), so the
 * lock only needs to be held at the moment the event arrives - see
 * EnergyLidCloseOnceArmer's rationale for releasing it right after. */
@interface EnergySystemdLidInhibitor : NSObject <EnergySleepInhibitor>
@end

@implementation EnergySystemdLidInhibitor
{
    NSTask *_task;
}

- (BOOL)startInhibitingLidHandlingWhy:(NSString *)why error:(NSError **)error
{
    if (_task != nil && [_task isRunning]) {
        return YES;
    }
    [self cleanupTask];

    NSString *bin = EnergyLidFindExecutable(@[@"/usr/bin/systemd-inhibit", @"/bin/systemd-inhibit"]);
    if (bin == nil) {
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"systemd-inhibit is not installed"}];
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:bin];
    /* --mode=block: logind must not act on the lid close at all (the screen
     * may still turn off on its own idle timeout - that is a separate,
     * unrelated inhibitor this feature does not touch). --mode=delay would
     * only postpone the suspend, which is not what "stay awake" asked for. */
    [task setArguments:[NSArray arrayWithObjects:
        @"--what=handle-lid-switch", @"--mode=block", @"--who=Battery",
        [NSString stringWithFormat:@"--why=%@", why], @"cat", nil]];
    /* The lock lives exactly as long as this command. cat blocks on a pipe
     * whose only writer is this process; NSTask closes inherited descriptors
     * in the child other than the ones it set up, so if Menu dies without
     * running -stopInhibiting, cat sees EOF on its own and the lock is
     * still released - the same mechanism EnergyController uses for its
     * --what=sleep lock. */
    [task setStandardInput:[NSPipe pipe]];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:
                                              @"systemd-inhibit failed to launch: %@",
                                              [exception reason]]}];
        }
        return NO;
    }
    _task = task;
    return YES;
}

- (void)stopInhibiting
{
    [self cleanupTask];
}

- (void)cleanupTask
{
    if (_task == nil) {
        return;
    }
    if ([_task isRunning]) {
        [_task terminate];
    }
    _task = nil;
}

- (BOOL)isInhibiting
{
    return _task != nil && [_task isRunning];
}

@end

#endif /* __linux__ */

@implementation EnergyLidBackend

#if defined(__linux__)

/* dbus_bus_get returns a connection shared and cached by libdbus for this
 * process; it must be unref'd when done with it (that only drops our
 * reference) but never closed (that would sever it for every other caller
 * in the process too) - unlike the private connection the event source
 * opens for itself in -threadMain:. */
+ (BOOL)linuxSupportedWithReason:(NSString **)reason
{
    if (EnergyLidFindExecutable(@[@"/usr/bin/systemd-inhibit", @"/bin/systemd-inhibit"]) == nil) {
        if (reason) {
            *reason = @"systemd-inhibit is not installed; cannot hold a lid-handling lock";
        }
        return NO;
    }

    DBusError err;
    dbus_error_init(&err);
    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (conn == NULL) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"no D-Bus system bus: %s",
                       err.message ? err.message : "unknown error"];
        }
        dbus_error_free(&err);
        return NO;
    }

    dbus_bool_t hasOwner = dbus_bus_name_has_owner(conn, "org.freedesktop.login1", &err);
    dbus_connection_unref(conn);
    if (dbus_error_is_set(&err)) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"could not reach logind: %s", err.message];
        }
        dbus_error_free(&err);
        return NO;
    }
    if (!hasOwner) {
        if (reason) {
            *reason = @"systemd-logind is not running on this system";
        }
        return NO;
    }
    return YES;
}

+ (EnergyLidCloseOnceArmer *)createArmerWithUnsupportedReason:(NSString **)reason
{
    NSString *why = nil;
    if (![self linuxSupportedWithReason:&why]) {
        if (reason) {
            *reason = why;
        }
        return nil;
    }
    id<EnergyLidEventSource> source = [[EnergyLidEventSourceLinuxDBus alloc] init];
    id<EnergySleepInhibitor> inhibitor = [[EnergySystemdLidInhibitor alloc] init];
    return [[EnergyLidCloseOnceArmer alloc] initWithLidEventSource:source inhibitor:inhibitor];
}

#else

/* FreeBSD and OpenBSD have no logind: the lid switch's suspend action is
 * wired up by devd.conf rules (FreeBSD) or not exposed at all in a way this
 * backend can intercept, so there is no portable way to hold this system to
 * the same "block the very next lid-close handling, once" contract Linux
 * gets from a logind inhibitor lock. Failing hard here (never handing out
 * an armer) is deliberate, not a gap: the alternative is a menu item that
 * looks armed and does nothing when the lid actually closes. */
+ (EnergyLidCloseOnceArmer *)createArmerWithUnsupportedReason:(NSString **)reason
{
    if (reason) {
        *reason = @"stay-awake-at-lid-close needs systemd-logind, which this platform does not have";
    }
    return nil;
}

#endif

@end
