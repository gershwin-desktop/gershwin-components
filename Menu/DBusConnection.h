/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// DBus connection wrapper for GNUstep
#import "DBusMenuLayout.h"

@interface GNUDBusConnection : NSObject <DBusMenuLayoutSource>

@property (nonatomic, assign) void *connection; // DBusConnection pointer (opaque)
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, strong) NSMutableDictionary *messageHandlers;

+ (GNUDBusConnection *)sessionBus;
- (BOOL)connect;
- (void)disconnect;
- (BOOL)isConnected;
- (BOOL)registerService:(NSString *)serviceName;

/* Delivers every signal of interfaceName to [target selector:info] on the
   main run loop, info holding "sender", "path" and "member".  Delivery is
   deferred because signals are seen while libdbus dispatches, which also
   happens in the middle of our own synchronous calls. */
- (BOOL)watchSignalsOfInterface:(NSString *)interfaceName
                         target:(id)target
                       selector:(SEL)selector;
- (BOOL)registerObjectPath:(NSString *)objectPath 
                 interface:(NSString *)interfaceName 
                   handler:(id)handler;
- (id)callMethod:(NSString *)method
      onService:(NSString *)serviceName
    objectPath:(NSString *)objectPath
     interface:(NSString *)interfaceName
     arguments:(NSArray *)arguments;
- (id)callGTKActivateMethod:(NSString *)actionName
                  parameter:(NSArray *)parameter
               platformData:(NSDictionary *)platformData
                  onService:(NSString *)serviceName
                 objectPath:(NSString *)objectPath;
- (void)processMessages;
- (BOOL)hasPendingMessages;
- (void *)rawConnection;
- (int)getFileDescriptor;

@end
