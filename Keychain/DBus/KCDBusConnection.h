/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <dbus/dbus.h>

@class KCDBusConnection;

@protocol KCDBusObjectHandler <NSObject>
/* Called for every method call below the registered path. */
- (void) connection: (KCDBusConnection *)connection
      handleMessage: (DBusMessage *)message;
@optional
/* A bus client went away (NameOwnerChanged to ""), so per-client state
 * such as open sessions can be dropped. */
- (void) connection: (KCDBusConnection *)connection
    clientDidVanish: (NSString *)uniqueName;
@end

/* A session bus connection that exports objects, driven by the NSRunLoop.
 *
 * gershwin-components' Menu has a libdbus wrapper too, but it is a client for
 * DBusMenu inside Menu.app that infers wire types from Objective-C objects;
 * a service needs exact reply signatures and server-side dispatch, and it
 * cannot link code from another repository, hence this small one. */
@interface KCDBusConnection : NSObject

/* modes: every run loop mode the bus is served in. An app passes its modal
 * and event tracking modes too, so a client waiting for its password is
 * never stalled by the user browsing a menu. */
- (instancetype) initWithSessionBus: (NSError **)error
                       runLoopModes: (NSArray *)modes;

/* Fails when another process owns the name: two secret services on one bus
 * would split a user's credentials between them. */
- (BOOL) requestName: (NSString *)name error: (NSError **)error;

- (void) registerFallbackPath: (NSString *)path
                      handler: (id<KCDBusObjectHandler>)handler;

- (void) replyTo: (DBusMessage *)call
       signature: (NSString *)signature
          values: (NSArray *)values;
- (void) replyTo: (DBusMessage *)call
       errorName: (NSString *)name
         message: (NSString *)text;
- (void) emitSignal: (NSString *)member
          interface: (NSString *)interface
               path: (NSString *)path
          signature: (NSString *)signature
             values: (NSArray *)values;

- (NSString *) uniqueName;

@end
