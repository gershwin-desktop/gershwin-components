/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Menus nest a few levels deep in practice; the limit only exists so an app
   that answers every hole with another hole cannot keep the menu bar's main
   thread in D-Bus calls forever. */
#define DBusMenuLayoutMaxDepth 6

/* The one D-Bus call the filler needs, so tests can script it. */
@protocol DBusMenuLayoutSource <NSObject>
- (id)callMethod:(NSString *)method
       onService:(NSString *)serviceName
      objectPath:(NSString *)objectPath
       interface:(NSString *)interfaceName
       arguments:(NSArray *)arguments;
@end

/* Works on the raw com.canonical.dbusmenu layout tree, before it becomes an
   NSMenu: a layout item is (id, properties, children), where properties
   arrive either as a dictionary or as an array of one-entry dictionaries.

   Electron (and other libdbusmenu users) create a submenu's children only
   when AboutToShow is called on it, so GetLayout of the whole tree returns
   empty top-level menus.  Filling the holes here, on the raw tree, means the
   parser sees a complete menu in one pass and registers the shortcuts of the
   fetched items like those of any other app.  Submenus that already have
   children are never touched, so apps that export a full tree (Chrome, Qt)
   see no extra D-Bus traffic. */
@interface DBusMenuLayout : NSObject

+ (NSDictionary *)propertiesOfLayoutItem:(id)layoutItem;
+ (NSDictionary *)dictionaryFromProperties:(id)propertiesObj;

+ (id)layoutItem:(id)layoutItem
withLazySubmenusFilledFromService:(NSString *)serviceName
      objectPath:(NSString *)objectPath
      connection:(id<DBusMenuLayoutSource>)connection;

@end
