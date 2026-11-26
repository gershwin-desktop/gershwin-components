/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* A rescan of the disks hands every pane a fresh instance of the selected
 * object with the same identifier. That is a refresh, not a new selection:
 * the format, name and partition the user chose must survive it. Choosing
 * another object in the sidebar resets them to the defaults. Each fresh
 * instance comes from a second mock backend, and the first backend is
 * released before the refresh, the way the old snapshot dies in the app. */

#import <AppKit/AppKit.h>
#import "Testing.h"

#import "DUEraseViewController.h"
#import "DUMockStorageBackend.h"
#import "DUOperationLogView.h"
#import "DUOperationManager.h"
#import "DUPartitionViewController.h"
#import "DUStorageManager.h"
#import "DUStorageObject.h"

// Private controls of the panes, read the way the user sees them.
@interface DUEraseViewController (TestAccess)
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSPopUpButton *formatPopup;
@end

@interface DUPartitionViewController (TestAccess)
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, assign) NSInteger selectedIndex;
- (void)mapView:(id)sender didSelectPartitionAtIndex:(NSUInteger)index;
- (void)controlTextDidChange:(NSNotification *)notification;
@end

static NSString * const kExternalDisk = @"mock-disk-external";
static NSString * const kInternalDisk = @"mock-disk-internal";

static DUStorageObject *Find(NSArray *objects, NSString *identifier)
{
    for (DUStorageObject *object in objects) {
        if ([object.identifier isEqualToString:identifier]) {
            return object;
        }
        DUStorageObject *found = Find(object.children, identifier);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

// A fresh instance of the object, as the next discovery delivers it. The
// backend is returned retained so the caller decides when it dies.
static DUStorageObject *Discover(NSString *identifier,
                                 DUMockStorageBackend **backendOut)
{
    DUMockStorageBackend *backend = [[DUMockStorageBackend alloc] init];
    *backendOut = backend;
    return Find(backend.rootObjects, identifier);
}

static void SelectFormat(NSPopUpButton *popup, NSString *identifier)
{
    NSInteger index = [popup indexOfItemWithRepresentedObject:identifier];
    [popup selectItemAtIndex:index];
    [popup sendAction:popup.action to:popup.target];
}

static NSString *SelectedFormat(NSPopUpButton *popup)
{
    return popup.selectedItem.representedObject;
}

static void TypeName(id pane, NSTextField *field, NSString *text)
{
    field.stringValue = text;
    if ([pane respondsToSelector:@selector(controlTextDidChange:)]) {
        [pane controlTextDidChange:
                  [NSNotification
                      notificationWithName:NSControlTextDidChangeNotification
                                    object:field]];
    }
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    [NSApplication sharedApplication];

    DUMockStorageBackend *managerBackend = [[DUMockStorageBackend alloc] init];
    DUStorageManager *manager = [[DUStorageManager alloc]
        initWithBackend:managerBackend
       operationManager:[[[DUOperationManager alloc] init] autorelease]];
    DUOperationLogView *log = [[DUOperationLogView alloc] init];

    START_SET("Erase pane")
    DUEraseViewController *erase =
        [[DUEraseViewController alloc] initWithStorageManager:manager
                                                      logView:log];
    DUMockStorageBackend *first = nil;
    DUMockStorageBackend *second = nil;
    NSString *defaultFormat = nil;
    NSString *defaultName = nil;

    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    DUStorageObject *disk = Discover(kExternalDisk, &first);
    NEED(PASS(disk != nil && disk.capabilities.canErase,
              "the mock external disk can be erased"));
    [erase refreshForObject:disk capabilities:disk.capabilities];
    defaultFormat = [SelectedFormat(erase.formatPopup) copy];
    defaultName = [disk.displayName copy];
    NEED(PASS(defaultFormat != nil && ![defaultFormat isEqual:@"exfat"],
              "the default format is not the one the user picks next"));
    SelectFormat(erase.formatPopup, @"exfat");
    TypeName(erase, erase.nameField, @"Typed Name");
    [pool release];
    [first release];

    pool = [NSAutoreleasePool new];
    disk = Discover(kExternalDisk, &second);
    [erase refreshForObject:disk capabilities:disk.capabilities];
    PASS_EQUAL(SelectedFormat(erase.formatPopup), @"exfat",
               "a refresh of the same disk keeps the chosen format");
    PASS_EQUAL(erase.nameField.stringValue, @"Typed Name",
               "a refresh of the same disk keeps the typed name");
    [pool release];

    pool = [NSAutoreleasePool new];
    DUStorageObject *other = Find(second.rootObjects, kInternalDisk);
    [erase refreshForObject:other capabilities:other.capabilities];
    PASS_EQUAL(SelectedFormat(erase.formatPopup), defaultFormat,
               "selecting another disk resets the format to the default");
    PASS_EQUAL(erase.nameField.stringValue, other.displayName,
               "selecting another disk prefills its own name");
    [pool release];
    [second release];

    // An untouched name follows the object, e.g. after it was renamed.
    pool = [NSAutoreleasePool new];
    disk = Discover(kExternalDisk, &first);
    [erase refreshForObject:disk capabilities:disk.capabilities];
    DUStorageObject *renamed = Discover(kExternalDisk, &second);
    renamed.displayName = @"Renamed Disk";
    [erase refreshForObject:renamed capabilities:renamed.capabilities];
    PASS_EQUAL(erase.nameField.stringValue, @"Renamed Disk",
               "a name the user did not edit follows the refreshed object");
    [pool release];
    [first release];
    [second release];
    [erase release];
    [defaultFormat release];
    [defaultName release];
    END_SET("Erase pane")

    START_SET("Partition pane")
    DUPartitionViewController *partition =
        [[DUPartitionViewController alloc] initWithStorageManager:manager
                                                          logView:log];
    DUMockStorageBackend *first = nil;
    DUMockStorageBackend *second = nil;

    // Choosing another partition tile is not an edit, so no pending plan
    // protects it; the refresh alone must keep it.
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    DUStorageObject *disk = Discover(kInternalDisk, &first);
    NEED(PASS(disk != nil && disk.capabilities.canPartition,
              "the mock internal disk can be partitioned"));
    [partition refreshForObject:disk capabilities:disk.capabilities];
    [partition mapView:nil didSelectPartitionAtIndex:2];
    NEED(PASS(partition.selectedIndex == 2, "the third partition is chosen"));
    [pool release];
    [first release];

    pool = [NSAutoreleasePool new];
    disk = Discover(kInternalDisk, &second);
    [partition refreshForObject:disk capabilities:disk.capabilities];
    PASS(partition.selectedIndex == 2,
         "a refresh of the same disk keeps the chosen partition");
    [pool release];
    [second release];

    // A typed name is a pending edit. The pane holds the disk weakly, so
    // the old instance is gone by the time the refresh arrives.
    pool = [NSAutoreleasePool new];
    disk = Discover(kInternalDisk, &first);
    [partition refreshForObject:disk capabilities:disk.capabilities];
    [partition mapView:nil didSelectPartitionAtIndex:1];
    TypeName(partition, partition.nameField, @"Edited");
    [pool release];
    [first release];

    pool = [NSAutoreleasePool new];
    disk = Discover(kInternalDisk, &second);
    [partition refreshForObject:disk capabilities:disk.capabilities];
    PASS_EQUAL(partition.nameField.stringValue, @"Edited",
               "a refresh of the same disk keeps the typed partition name");
    PASS(partition.selectedIndex == 1,
         "a refresh with pending edits keeps the chosen partition");

    DUStorageObject *other = Find(second.rootObjects, kExternalDisk);
    [partition refreshForObject:other capabilities:other.capabilities];
    PASS(partition.selectedIndex == 0,
         "selecting another disk starts at its first partition");
    PASS(![partition.nameField.stringValue isEqual:@"Edited"],
         "selecting another disk drops the other disk's typed name");
    [pool release];
    [second release];
    [partition release];
    END_SET("Partition pane")

    [log release];
    [manager release];
    [managerBackend release];
    [arp release];
    return 0;
}
