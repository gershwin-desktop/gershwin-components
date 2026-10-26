/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: GPL-2.0-or-later OR BSD-2-Clause
 */

#import "EnergyLidBackend.h"

#if defined(__linux__)
#import <dbus/dbus.h>
#import <string.h>
#import <unistd.h>

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

/* The polkit action this call is gated behind, named in every error this
 * class reports so a denial tells the user exactly what to allow. */
static NSString *const kEnergyLidPolkitAction = @"org.freedesktop.login1.inhibit-handle-lid-switch";

/* A logind "handle-lid-switch" block-mode lock, taken through the Manager's
 * own Inhibit() D-Bus method rather than the systemd-inhibit binary: that
 * method is logind's actual API (systemd-inhibit is just a thin wrapper
 * around it), so this works identically against systemd-logind and against
 * elogind, and needs no external executable at all - only whichever of the
 * two provides org.freedesktop.login1 on the system bus.
 *
 * Inhibit() returns a pipe file descriptor; holding it open is the lock,
 * closing it (or the process dying, which closes every fd) releases it -
 * so, same as the old systemd-inhibit child process, a Menu that dies
 * without calling -stopInhibiting still releases the lock on its own.
 *
 * While held, logind performs no action at all for a lid-close event (it
 * does not suspend now, and it does not queue the suspend for later), so
 * the lock only needs to be held at the moment the event arrives - see
 * EnergyLidCloseOnceArmer's rationale for releasing it right after. */
@interface EnergyLogindLidInhibitor : NSObject <EnergySleepInhibitor>
@end

@implementation EnergyLogindLidInhibitor
{
    int _fd;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fd = -1;
    }
    return self;
}

- (BOOL)startInhibitingLidHandlingWhy:(NSString *)why error:(NSError **)error
{
    if (_fd >= 0) {
        return YES;
    }

    DBusError err;
    dbus_error_init(&err);
    DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
    if (conn == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"no D-Bus system bus: %s",
                                              err.message ? err.message : "unknown error"]}];
        }
        dbus_error_free(&err);
        return NO;
    }

    DBusMessage *msg = dbus_message_new_method_call("org.freedesktop.login1",
                                                     "/org/freedesktop/login1",
                                                     "org.freedesktop.login1.Manager",
                                                     "Inhibit");
    const char *what = "handle-lid-switch";
    const char *who = "Gershwin";
    const char *whyUTF8 = [why UTF8String];
    const char *mode = "block";
    dbus_message_append_args(msg,
                              DBUS_TYPE_STRING, &what,
                              DBUS_TYPE_STRING, &who,
                              DBUS_TYPE_STRING, &whyUTF8,
                              DBUS_TYPE_STRING, &mode,
                              DBUS_TYPE_INVALID);

    DBusMessage *reply = dbus_connection_send_with_reply_and_block(conn, msg, -1, &err);
    dbus_message_unref(msg);
    dbus_connection_unref(conn);

    if (reply == NULL) {
        /* The expected denial while nothing is actively using this: polkit's
         * org.freedesktop.login1.inhibit-handle-lid-switch only grants this
         * to the active session, so a call from outside one (or before the
         * user has allowed it) is refused here, not silently ignored. */
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:
                                              @"logind refused the lid-close lock (%s: %s) - "
                                              @"needs the polkit action %@ allowed for this session",
                                              err.name ? err.name : "error",
                                              err.message ? err.message : "no details",
                                              kEnergyLidPolkitAction]}];
        }
        dbus_error_free(&err);
        return NO;
    }

    int fd = -1;
    if (!dbus_message_get_args(reply, &err, DBUS_TYPE_UNIX_FD, &fd, DBUS_TYPE_INVALID) || fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:EnergyLidCloseOnceErrorDomain
                                          code:4
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:
                                              @"logind did not hand back a lock: %s",
                                              dbus_error_is_set(&err) ? err.message : "no file descriptor"]}];
        }
        dbus_error_free(&err);
        dbus_message_unref(reply);
        return NO;
    }
    dbus_message_unref(reply);

    _fd = fd;
    return YES;
}

- (void)stopInhibiting
{
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

- (BOOL)isInhibiting
{
    return _fd >= 0;
}

- (void)dealloc
{
    [self stopInhibiting];
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
            *reason = @"no logind on this system (neither systemd-logind nor elogind is running)";
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
    id<EnergySleepInhibitor> inhibitor = [[EnergyLogindLidInhibitor alloc] init];
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
        *reason = @"stay-awake-at-lid-close needs a logind D-Bus API "
                  @"(systemd-logind or elogind), which this platform does not have";
    }
    return nil;
}

#endif

@end
