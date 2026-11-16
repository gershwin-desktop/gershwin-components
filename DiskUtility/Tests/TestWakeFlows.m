/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* A removable disk ejected while still plugged in shows up with no size
 * and no partitions. Commands that read the medium must start it first
 * through -[DUStorageManager wakeObject:completion:] and then run on the
 * disk as discovered afterwards, not on the empty instance the user
 * selected. Checked for First Aid (Verify) and Erase, whose operations
 * would otherwise act on a disk with nothing on it. */

#import <AppKit/AppKit.h>
#import "Testing.h"

#import "DUEraseViewController.h"
#import "DUFirstAidViewController.h"
#import "DUNotifications.h"
#import "DUOperation.h"
#import "DUOperationLogView.h"
#import "DUOperationManager.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "TestControllableBackend.h"

// The panes' button actions, driven the way a click would.
@interface DUFirstAidViewController (TestAccess)
- (void)verifyDisk:(id)sender;
@end

@interface DUEraseViewController (TestAccess)
- (void)eraseClicked:(id)sender;
@end

static NSString * const kDisk = @"mock-disk-external";

// Records which object each operation started on.
@interface StartRecorder : NSObject
@property (nonatomic, retain) NSMutableArray *started;
@end

@implementation StartRecorder
- (void)operationStarted:(NSNotification *)note
{
    id object = note.userInfo[kDUUserInfoObjectKey];
    if (object != nil) {
        [self.started addObject:object];
    }
}
@end

static void Pump(BOOL (^done)(void))
{
    for (int i = 0; i < 100 && !done(); i++) {
        [[NSRunLoop currentRunLoop]
               runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

// The external mock disk as discovery shows it after Eject: same
// identifier, no medium, no partitions, the commands still offered.
static DUStorageDevice *Ejected(void)
{
    DUStorageDevice *disk =
        [[[DUStorageDevice alloc] initWithIdentifier:kDisk] autorelease];
    disk.displayName = @"USB Disk (Ejected)";
    disk.mediumEjected = YES;
    disk.capabilities.canVerify = YES;
    disk.capabilities.canErase = YES;
    return disk;
}

static DUStorageObject *Awake(DUControllableBackend *backend)
{
    for (DUStorageObject *root in backend.rootObjects) {
        if ([root.identifier isEqualToString:kDisk]) {
            return root;
        }
    }
    return nil;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    [NSApplication sharedApplication];
    // No confirmation panels in an unattended run.
    [[NSUserDefaults standardUserDefaults]
        setVolatileDomain:@{ @"DUConfirmDestructiveOperations" : @NO }
                  forName:@"DUWakeFlowsTest"];
    [[NSUserDefaults standardUserDefaults]
        setSearchList:[@[ @"DUWakeFlowsTest" ]
                          arrayByAddingObjectsFromArray:
                              [[NSUserDefaults standardUserDefaults]
                                  searchList]]];

    DUControllableBackend *backend = [[DUControllableBackend alloc] init];
    DUStorageObject *awake = Awake(backend);
    DUStorageManager *manager = [[DUStorageManager alloc]
        initWithBackend:backend
       operationManager:[[[DUOperationManager alloc] init] autorelease]];
    DUOperationLogView *log = [[DUOperationLogView alloc] init];
    StartRecorder *recorder = [[StartRecorder alloc] init];
    recorder.started = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter]
        addObserver:recorder
           selector:@selector(operationStarted:)
               name:DUOperationDidStartNotification
             object:nil];

    START_SET("First Aid wakes the disk before verifying")
        DUStorageDevice *ejected = Ejected();
        backend.nextDiscovery = @[ ejected ];
        backend.discoveryAfterStart = backend.rootObjects;
        backend.startCount = 0;
        [manager refreshWithError:NULL];
        [recorder.started removeAllObjects];
        DUFirstAidViewController *firstAid =
            [[DUFirstAidViewController alloc] initWithStorageManager:manager
                                                             logView:log];
        [firstAid refreshForObject:ejected capabilities:ejected.capabilities];
        [firstAid verifyDisk:nil];
        Pump(^BOOL { return recorder.started.count > 0; });
        PASS(backend.startCount == 1, "the disk was started once");
        PASS(recorder.started.count == 1 &&
             recorder.started[0] == awake,
             "Verify ran on the disk as discovered after starting");
        [firstAid release];
    END_SET("First Aid wakes the disk before verifying")

    START_SET("Erase wakes the disk before erasing")
        DUStorageDevice *ejected = Ejected();
        backend.nextDiscovery = @[ ejected ];
        backend.discoveryAfterStart = backend.rootObjects;
        backend.startCount = 0;
        [manager refreshWithError:NULL];
        Pump(^BOOL { return NO; });
        [recorder.started removeAllObjects];
        DUEraseViewController *erase =
            [[DUEraseViewController alloc] initWithStorageManager:manager
                                                          logView:log];
        [erase refreshForObject:ejected capabilities:ejected.capabilities];
        [erase eraseClicked:nil];
        Pump(^BOOL { return recorder.started.count > 0; });
        PASS(backend.startCount == 1, "the disk was started once");
        PASS(recorder.started.count == 1 &&
             recorder.started[0] == awake,
             "Erase ran on the disk as discovered after starting");
        [erase release];
    END_SET("Erase wakes the disk before erasing")

    START_SET("A disk that does not start runs nothing")
        DUStorageDevice *ejected = Ejected();
        backend.nextDiscovery = @[ ejected ];
        backend.failStart = YES;
        backend.startCount = 0;
        [manager refreshWithError:NULL];
        Pump(^BOOL { return NO; });
        [recorder.started removeAllObjects];
        DUFirstAidViewController *firstAid =
            [[DUFirstAidViewController alloc] initWithStorageManager:manager
                                                             logView:log];
        [firstAid refreshForObject:ejected capabilities:ejected.capabilities];
        [firstAid verifyDisk:nil];
        Pump(^BOOL { return NO; });
        PASS(backend.startCount == 1 && recorder.started.count == 0,
             "no operation starts on a disk that could not be started");
        [firstAid release];
    END_SET("A disk that does not start runs nothing")

    [[NSNotificationCenter defaultCenter] removeObserver:recorder];
    [recorder release];
    [log release];
    [manager release];
    [backend release];
    [arp release];
    return 0;
}
