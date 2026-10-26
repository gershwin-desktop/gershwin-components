/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Every rescan of the disks hands the sidebar a fresh tree with the same
 * identifiers. A volume sits two levels deep (disk > partition > volume),
 * so it is only on screen while its partition is expanded. The reload used
 * to restore expansion for the disks only: the selected volume then had no
 * row, -rowForItem: answered -1, and NSIndexSet raised an NSRangeException
 * out of the topology notification on every rescan, leaving the sidebar
 * showing a selection the app no longer tracked. */

#import <AppKit/AppKit.h>
#import "Testing.h"

#import "DUDeviceBrowserController.h"
#import "DUMockStorageBackend.h"
#import "DUOperationManager.h"
#import "DUPartition.h"
#import "DUStorageDevice.h"
#import "DUStorageManager.h"
#import "DUStorageVolume.h"

@interface DUDeviceBrowserController (TestAccess)
@property (nonatomic, strong) NSOutlineView *outlineView;
@end

// Serves a tree the test swaps out, the way discovery replaces the snapshot.
@interface TestTreeManager : DUStorageManager
@property (nonatomic, copy) NSArray *tree;
@end

@implementation TestTreeManager
- (NSArray *)currentObjects
{
    return self.tree;
}
@end

// The user's stick as discovery builds it; every call returns new objects.
static NSArray *FreshTree(void)
{
    DUStorageDevice *disk =
        [[[DUStorageDevice alloc] initWithIdentifier:@"linux-disk-sdb"]
            autorelease];
    disk.displayName = @"DataTraveler 3.0 (14.4 GB)";
    DUPartition *partition =
        [[[DUPartition alloc] initWithIdentifier:@"linux-part-sdb1"]
            autorelease];
    partition.displayName = @"DATATRAVELE (14.4 GB)";
    DUStorageVolume *volume =
        [[[DUStorageVolume alloc] initWithIdentifier:@"linux-vol-sdb1"]
            autorelease];
    volume.displayName = @"DATATRAVELE (14.4 GB)";
    partition.volume = volume;
    [partition addChild:volume];
    [disk addChild:partition];

    DUStorageDevice *other =
        [[[DUStorageDevice alloc] initWithIdentifier:@"linux-disk-sda"]
            autorelease];
    other.displayName = @"TOSHIBA (465.8 GB)";
    return @[ other, disk ];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    [NSApplication sharedApplication];

    TestTreeManager *manager = [[TestTreeManager alloc]
        initWithBackend:[[[DUMockStorageBackend alloc] init] autorelease]
       operationManager:[[[DUOperationManager alloc] init] autorelease]];
    manager.tree = FreshTree();
    DUDeviceBrowserController *browser =
        [[DUDeviceBrowserController alloc] initWithStorageManager:manager];
    [browser reloadWithPreferredSelection:nil];

    START_SET("Volume selection survives a rescan")
        NSOutlineView *outline = browser.outlineView;
        DUStorageObject *disk = manager.tree[1];
        DUStorageObject *partition = disk.children[0];
        DUStorageObject *volume = partition.children[0];
        [outline expandItem:disk];
        [outline expandItem:partition];
        [outline selectRowIndexes:
                     [NSIndexSet indexSetWithIndex:[outline rowForItem:volume]]
             byExtendingSelection:NO];
        PASS_EQUAL(browser.selectedObject.identifier, @"linux-vol-sdb1",
                   "the volume is selected before the rescan");

        manager.tree = FreshTree();
        BOOL raised = NO;
        NS_DURING
            [browser reloadWithPreferredSelection:@"linux-vol-sdb1"];
        NS_HANDLER
            raised = YES;
        NS_ENDHANDLER
        PASS(!raised, "reloading a fresh tree raises no exception");
        PASS_EQUAL(browser.selectedObject.identifier, @"linux-vol-sdb1",
                   "the volume is still selected after the rescan");
        DUStorageObject *freshVolume =
            [[manager.tree[1] children][0] children][0];
        PASS(browser.selectedObject == freshVolume,
             "the selection is the fresh volume, not the stale one");
        PASS([outline isItemExpanded:[manager.tree[1] children][0]],
             "the partition stays expanded");
    END_SET("Volume selection survives a rescan")

    START_SET("A deep selection is revealed even when collapsed")
        NSOutlineView *outline = browser.outlineView;
        [outline collapseItem:manager.tree[1] collapseChildren:YES];
        manager.tree = FreshTree();
        BOOL raised = NO;
        NS_DURING
            [browser reloadWithPreferredSelection:@"linux-vol-sdb1"];
        NS_HANDLER
            raised = YES;
        NS_ENDHANDLER
        PASS(!raised, "selecting a hidden volume raises no exception");
        PASS_EQUAL(browser.selectedObject.identifier, @"linux-vol-sdb1",
                   "the hidden volume is revealed and selected");
    END_SET("A deep selection is revealed even when collapsed")

    [browser release];
    [manager release];
    [arp release];
    return 0;
}
