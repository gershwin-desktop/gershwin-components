/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "DUDeviceMonitor.h"
#import "DUNotifications.h"
#import "DUErrors.h"
#import "DUMockStorageBackend.h"
#import "DUOperationManager.h"
#import "DUStorageManager.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "TestControllableBackend.h"

static int gPassed = 0;
static int gFailed = 0;

static void Check(BOOL condition, NSString *what)
{
    if (condition) {
        gPassed++;
        printf("  ok   %s\n", what.UTF8String);
    } else {
        gFailed++;
        printf("  FAIL %s\n", what.UTF8String);
    }
    fflush(stdout);
}

// The description is a plain C literal so the assertions read like
// prose rather than like an Objective-C call.
#define PASS(expression__, what__) Check((expression__), @what__)

// Every object in a tree, one level down, so a test can look one up by id.
static DUStorageObject *FindByIdentifier(NSArray *roots, NSString *identifier)
{
    if (identifier.length == 0) {
        return nil;
    }
    for (DUStorageObject *root in roots) {
        if ([root.identifier isEqualToString:identifier]) {
            return root;
        }
        for (DUStorageObject *child in root.children) {
            if ([child.identifier isEqualToString:identifier]) {
                return child;
            }
        }
    }
    return nil;
}

static BOOL Contains(NSArray *roots, NSString *identifier)
{
    return FindByIdentifier(roots, identifier) != nil;
}

// The pristine mock tree minus one root, which is what a poll sees while the
// device in question is unreadable.
static NSArray *WithoutRoot(NSArray *roots, NSString *identifier)
{
    NSMutableArray *kept = [NSMutableArray array];
    for (DUStorageObject *root in roots) {
        if (![root.identifier isEqualToString:identifier]) {
            [kept addObject:root];
        }
    }
    return kept;
}

static DUStorageManager *ManagerFor(DUControllableBackend *backend)
{
    return [[DUStorageManager alloc]
        initWithBackend:backend
         operationManager:[[DUOperationManager alloc] init]];
}

// Turns the run loop for a moment, so work posted to the main thread (the
// topology notification) actually gets delivered before it is counted.
static void PumpRunLoop(NSTimeInterval seconds)
{
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:
                                            seconds]];
}

int main(void)
{
    @autoreleasepool {
        // --- no snapshot before the first refresh ---
        DUControllableBackend *freshBackend =
            [[DUControllableBackend alloc] init];
        freshBackend.nextDiscovery = freshBackend.rootObjects;
        DUStorageManager *untouched = ManagerFor(freshBackend);
        PASS(untouched.currentObjects.count == 0,
             "no snapshot before the first refresh");

        // --- a failed refresh keeps the previous snapshot ---
        DUControllableBackend *backend = [[DUControllableBackend alloc] init];
        backend.nextDiscovery = backend.rootObjects;
        DUStorageManager *manager = ManagerFor(backend);
        PASS([manager refreshWithError:NULL] == YES,
             "first refresh publishes a snapshot");
        NSUInteger before = manager.currentObjects.count;
        backend.failNextDiscovery = YES;
        NSError *error = nil;
        PASS([manager refreshWithError:&error] == NO,
             "a failed refresh reports failure");
        PASS(error != nil, "and carries an error");
        PASS(manager.currentObjects.count == before,
             "and keeps the previous snapshot");

        // --- a busy device is carried forward, not deleted ---
        NSString *target = manager.currentObjects.firstObject.identifier;
        PASS(target.length > 0, "the snapshot has a device to work on");
        PASS([manager acquireLock:target error:NULL] == YES,
             "an operation can take the device");
        backend.nextDiscovery = WithoutRoot(backend.rootObjects, target);
        PASS([manager refreshWithError:NULL] == YES,
             "the poll that no longer sees the device still runs");
        PASS(Contains(manager.currentObjects, target),
             "a busy device is carried forward rather than deleted from the UI");
        PASS([manager isBusyIdentifier:target], "and it stays locked");

        // ...and once the operation is done the real state wins again.
        [manager releaseLock:target];
        PASS([manager refreshWithError:NULL] == YES, "a later poll runs");
        PASS(!Contains(manager.currentObjects, target),
             "after the lock is released the device really does disappear");

        // --- a busy subtree keeps its children and its parent link ---
        DUControllableBackend *subtreeBackend =
            [[DUControllableBackend alloc] init];
        subtreeBackend.nextDiscovery = subtreeBackend.rootObjects;
        DUStorageManager *subtreeManager = ManagerFor(subtreeBackend);
        PASS([subtreeManager refreshWithError:NULL] == YES,
             "the subtree fixture publishes a snapshot");
        DUStorageObject *disk = subtreeManager.currentObjects.firstObject;
        NSString *childId = disk.children.firstObject.identifier;
        PASS(childId.length > 0, "the device has a child to protect");
        PASS([subtreeManager acquireLock:childId error:NULL] == YES,
             "the child volume can be locked");
        NSMutableArray *shallow = [NSMutableArray array];
        for (DUStorageObject *root in subtreeBackend.rootObjects) {
            DUStorageDevice *bare = [[DUStorageDevice alloc]
                initWithIdentifier:root.identifier];
            bare.displayName = root.displayName;
            [shallow addObject:bare];
        }
        subtreeBackend.nextDiscovery = shallow;
        PASS([subtreeManager refreshWithError:NULL] == YES,
             "a poll that sees the same disk with no partitions runs");
        DUStorageObject *carried =
            FindByIdentifier(subtreeManager.currentObjects, childId);
        PASS(carried != nil, "the busy child is still in the snapshot");
        PASS(carried.parent != nil,
             "and is still attached to its parent");
        [subtreeManager releaseLock:childId];

        // --- an idle device is NOT protected: the guard must not hide a
        //     genuine change ---
        DUControllableBackend *idleBackend =
            [[DUControllableBackend alloc] init];
        idleBackend.nextDiscovery = idleBackend.rootObjects;
        DUStorageManager *idleManager = ManagerFor(idleBackend);
        PASS([idleManager refreshWithError:NULL] == YES,
             "the idle fixture publishes a snapshot");
        NSString *idleId = idleManager.currentObjects.firstObject.identifier;
        idleBackend.nextDiscovery = WithoutRoot(idleBackend.rootObjects,
                                                idleId);
        PASS([idleManager refreshWithError:NULL] == YES, "the poll runs");
        PASS(!Contains(idleManager.currentObjects, idleId),
             "an idle device that went away is removed");

        // --- a poll that differs only by a busy device is not a change ---
        DUControllableBackend *quietBackend =
            [[DUControllableBackend alloc] init];
        quietBackend.nextDiscovery = quietBackend.rootObjects;
        DUStorageManager *quietManager = ManagerFor(quietBackend);
        PASS([quietManager refreshWithError:NULL] == YES,
             "the quiet fixture publishes a snapshot");
        NSString *quietId = quietManager.currentObjects.firstObject.identifier;
        [quietManager acquireLock:quietId error:NULL];
        quietBackend.nextDiscovery =
            WithoutRoot(quietBackend.rootObjects, quietId);
        // The only difference from the previous snapshot is that a device an
        // operation holds has vanished, so the reconciliation must produce the
        // same tree back and leave the UI exactly as it was.
        PASS([quietManager refreshWithError:NULL] == YES,
             "a poll whose only difference is a busy device still runs");
        PASS(Contains(quietManager.currentObjects, quietId),
             "and leaves the busy device in place");
        [quietManager releaseLock:quietId];

        // --- the lock itself ---
        DUControllableBackend *lockBackend =
            [[DUControllableBackend alloc] init];
        lockBackend.nextDiscovery = lockBackend.rootObjects;
        DUStorageManager *lockManager = ManagerFor(lockBackend);
        PASS([lockManager refreshWithError:NULL] == YES,
             "the lock fixture publishes a snapshot");
        NSString *lockId = lockManager.currentObjects.firstObject.identifier;
        PASS([lockManager acquireLock:lockId error:NULL] == YES,
             "the first lock wins");
        NSError *busyError = nil;
        PASS([lockManager acquireLock:lockId error:&busyError] == NO,
             "a second lock on the same device is refused");
        PASS(busyError != nil && busyError.code == DUErrorDeviceBusy,
             "and it reports the device as busy");
        [lockManager releaseLock:lockId];
        PASS([lockManager acquireLock:lockId error:NULL] == YES,
             "it can be locked again once released");
        [lockManager releaseLock:lockId];

        // --- the monitor starts and stops without wedging ---
        DUControllableBackend *monitorBackend =
            [[DUControllableBackend alloc] init];
        monitorBackend.nextDiscovery = monitorBackend.rootObjects;
        DUStorageManager *monitorManager = ManagerFor(monitorBackend);
        DUDeviceMonitor *monitor =
            [[DUDeviceMonitor alloc] initWithStorageManager:monitorManager];
        [monitor start];
        PumpRunLoop(0.3);
        [monitor stop];
        PASS(YES, "the device monitor starts and stops without wedging");
    }
    printf("\n== summary ==\n  %d passed, %d failed\n", gPassed, gFailed);
    return gFailed == 0 ? 0 : 1;
}
