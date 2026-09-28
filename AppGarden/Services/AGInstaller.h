/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "AGInstallTask.h"

@class AGApp, AGCatalog, AGInstallRegistry;

/*
 * Posted on the main thread whenever a task's progress or state changes.
 * object is the AGInstallTask. Cards, the detail page and the Installed page
 * observe it for their own app name, which is what keeps a button that
 * scrolled out of view and back in sync without polling.
 */
extern NSString *const AGInstallerTaskDidChangeNotification;

/*
 * Posted on the main thread after an install finished or a removal deleted a
 * file. object is the AGInstaller.
 */
extern NSString *const AGInstallerInstalledSetDidChangeNotification;

typedef NS_ENUM(NSInteger, AGInstallState) {
    AGInstallStateNotInstalled = 0,
    AGInstallStateDownloading,
    AGInstallStateInstalled,
    AGInstallStateFailed
};

@interface AGInstaller : NSObject

- (instancetype)initWithRegistry:(AGInstallRegistry *)registry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, strong) AGInstallRegistry *registry;

- (AGInstallState)stateForApp:(AGApp *)app;

/* The running or failed task for this app, else nil. */
- (AGInstallTask *)taskForApp:(AGApp *)app;

/*
 * Starts the install on a serial queue and returns the task immediately.
 * AGDownloadKindWebPageOnly and AGDownloadKindNone never reach this: the
 * button opens a page instead, so reaching them here is a programming error.
 */
- (AGInstallTask *)installApp:(AGApp *)app;

- (void)cancelTask:(AGInstallTask *)task;

- (BOOL)launchApp:(AGApp *)app error:(NSError **)error;

/*
 * Shows the installed file in the file manager instead of starting it: a
 * Distributed Objects call to the Workspace application, which selects the
 * file in a viewer. This is what the Open button runs. Returns NO with error
 * set when the file is gone or the file manager cannot be reached.
 */
- (BOOL)revealApp:(AGApp *)app error:(NSError **)error;

- (BOOL)removeApp:(AGApp *)app error:(NSError **)error;

/*
 * Registry entries that still exist on disk, as the catalog's AGApp objects,
 * in catalog order. Entries the catalog no longer carries cannot be shown as
 * cards and are dropped from the registry by the same reconcile pass.
 */
- (NSArray<AGApp *> *)installedAppsFromCatalog:(AGCatalog *)catalog;

@end
