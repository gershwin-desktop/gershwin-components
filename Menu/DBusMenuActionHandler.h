/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

@interface DBusMenuActionHandler : NSObject

// Set up action handling for a menu item
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                   serviceName:(NSString *)serviceName
                    objectPath:(NSString *)objectPath
                dbusConnection:(GNUDBusConnection *)dbusConnection;

// Menu item action handler
+ (void)menuItemAction:(id)sender;

/* The id to send in an Event for menuItem: the app's current id for the
   item's title path, or the id from the last fetch when the app has no
   item under that path any more. */
+ (int)currentItemIdForMenuItem:(NSMenuItem *)menuItem
                    serviceName:(NSString *)serviceName
                     objectPath:(NSString *)objectPath
                 dbusConnection:(GNUDBusConnection *)dbusConnection;

// Settings for Ctrl/Alt swapping
+ (BOOL)shouldSwapCtrlAlt;
+ (void)setSwapCtrlAlt:(BOOL)swap;

// Cleanup method
+ (void)cleanup;

@end
