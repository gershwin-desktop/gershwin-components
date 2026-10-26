/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGApp;

/*
 * What AppGarden has installed, as a plist at
 * ~/Library/AppGarden/Installed.plist: a dictionary keyed by app name with
 * {path, installedAt, displayName}. It survives the catalog entry itself
 * disappearing from a later feed, which is the only reason it exists; the
 * on-disk file stays the source of truth for whether an app is installed.
 */
@interface AGInstallRegistry : NSObject

/* Designated initializer; tests point it at a temporary directory. */
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;

/* ~/Library/AppGarden */
- (instancetype)init;

@property (nonatomic, readonly, copy) NSString *directory;

- (NSArray<NSString *> *)installedNames;

/* {path, installedAt, displayName} or nil. */
- (NSDictionary<NSString *, id> *)entryForName:(NSString *)name;

- (void)recordApp:(AGApp *)app path:(NSString *)path;

- (void)removeEntryForName:(NSString *)name;

/*
 * Drops every entry whose file is gone and writes the result. Deleting an
 * AppImage in the file manager must not leave a ghost row on the Installed
 * page, so this runs before the queries the UI makes; it is state
 * reconciliation, not an error path.
 */
- (void)reconcile;

@end
