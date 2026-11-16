/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Replays the layout of a real "DataTraveler 3.0" USB stick (one FAT32
 * partition labelled DATATRAVELE) through Linux discovery. Mount, unmount
 * and the ext usage readout act on the volume row's device node; discovery
 * once left it empty, so Mount on the volume answered "No device to
 * mount." */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "TestFixtures.h"

#if defined(__linux__)

#import "DULinuxDeviceDiscovery.h"
#import "DULinuxUserMount.h"
#import "DUPartition.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

static NSArray *Discover(NSString *name)
{
    DULinuxDeviceDiscovery *discovery =
        [[[DULinuxDeviceDiscovery alloc] init] autorelease];
    return [discovery
        discoverObjectsFromLsblkPairs:
            TestFixtureNamed([NSString stringWithFormat:
                                  @"Linux/%@-lsblk-pairs.txt", name])
                          blkidOutput:
            TestFixtureNamed([NSString stringWithFormat:
                                  @"Linux/%@-blkid.txt", name])];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    // Eject needs eject(1); without it no row may offer it.
    BOOL haveEject = [DULinuxToolCache haveTool:@"eject"];

    START_SET("DataTraveler volume")
        DULinuxDeviceDiscovery *discovery =
            [[[DULinuxDeviceDiscovery alloc] init] autorelease];
        NSArray *roots = [discovery
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/datatraveler-lsblk-pairs.txt")
                              blkidOutput:
                TestFixtureNamed(@"Linux/datatraveler-blkid.txt")];
        PASS(roots.count == 1, "one disk");
        DUStorageObject *disk = roots.firstObject;
        PASS_EQUAL(disk.backendPath, @"/dev/sdb", "disk node");
        DUPartition *partition = (DUPartition *)disk.children.firstObject;
        PASS_EQUAL(partition.backendPath, @"/dev/sdb1", "partition node");
        DUStorageVolume *volume = partition.volume;
        PASS(volume != nil && [partition.children containsObject:volume],
             "the FAT partition carries a volume row");
        PASS_EQUAL(volume.backendPath, @"/dev/sdb1",
                   "the volume row knows its device node");
        PASS_EQUAL(volume.filesystemType, @"vfat", "filesystem type");
        PASS([volume.displayName hasPrefix:@"DATATRAVELE"],
             "the volume is named after its 11-character label");
        PASS(volume.capabilities.canMount && !volume.mounted,
             "an unmounted volume offers Mount");

        PASS([DULinuxUserMount isUserMountable:volume],
             "the stick is mounted as the user, through udevil");
        PASS_EQUAL([DULinuxUserMount
                       mountPointFromOutput:
                           @"Mounted /dev/sdb1 at /media/admin/DATATRAVELE\n"
                                     device:@"/dev/sdb1"],
                   @"/media/admin/DATATRAVELE",
                   "the mount point is read from udevil's report");
        PASS([DULinuxUserMount
                 mountPointFromOutput:@"Mounted /dev/sdb10 at /media/admin/X\n"
                               device:@"/dev/sdb1"] == nil,
             "a report about another device names no mount point");

        PASS(disk.capabilities.canMount,
             "Mount is offered on the whole stick");
        PASS(disk.capabilities.canEject == haveEject &&
             partition.capabilities.canEject == haveEject &&
             volume.capabilities.canEject == haveEject,
             "Eject is offered on the disk, partition and volume rows");
    END_SET("DataTraveler volume")

    START_SET("USB disk with FAT32, ext4, swap and an empty partition")
        /* Recorded from a loop device carrying that layout, renamed to
         * the sdc a USB disk would get (TYPE disk, RM/HOTPLUG 1). */
        NSArray *roots = Discover(@"usb-four-partitions");
        PASS(roots.count == 1, "one disk");
        DUStorageObject *disk = roots.firstObject;
        PASS(disk.children.count == 4, "four partitions");
        NSArray *volumes = [DULinuxUserMount volumesOfObject:disk];
        PASS(volumes.count == 2, "only FAT32 and ext4 carry volumes");
        PASS_EQUAL([volumes valueForKey:@"backendPath"],
                   (@[ @"/dev/sdc1", @"/dev/sdc2" ]),
                   "the volumes in disk order");
        PASS([[volumes valueForKeyPath:@"capabilities.canMount"]
                 isEqual:(@[ @YES, @YES ])],
             "both volumes can be mounted");
        PASS(disk.capabilities.canMount,
             "Mount on the disk mounts its volumes");
        PASS(!disk.capabilities.canUnmount,
             "nothing is mounted, so nothing to unmount");
        DUStorageObject *swap = disk.children[2];
        DUStorageObject *empty = disk.children[3];
        PASS(!swap.capabilities.canMount && !empty.capabilities.canMount,
             "swap and the empty partition cannot be mounted");
        BOOL everyRowEjects = YES;
        for (DUStorageObject *row in disk.children) {
            everyRowEjects = everyRowEjects &&
                row.capabilities.canEject == haveEject;
        }
        PASS(disk.capabilities.canEject == haveEject && everyRowEjects,
             "every row of the disk offers Eject");
    END_SET("USB disk with FAT32, ext4, swap and an empty partition")

    START_SET("Volume names without blkid")
        /* blkid as an ordinary user cannot read the disk nodes; lsblk
         * still knows the labels from udev. */
        NSArray *roots = [[[[DULinuxDeviceDiscovery alloc] init] autorelease]
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/usb-four-partitions-lsblk-pairs.txt")
                              blkidOutput:@""];
        NSArray *volumes =
            [DULinuxUserMount volumesOfObject:roots.firstObject];
        PASS([[volumes[0] displayName] hasPrefix:@"DATATRAVELE"] &&
             [[volumes[1] displayName] hasPrefix:@"LINUXDATA"],
             "volumes are named after their labels from lsblk");
    END_SET("Volume names without blkid")

    START_SET("Partition scheme and types")
        DULinuxDeviceDiscovery *mbrDiscovery =
            [[[DULinuxDeviceDiscovery alloc] init] autorelease];
        /* The user's DataTraveler stick: an MBR table, one FAT32 (LBA)
         * partition. */
        DUStorageDevice *stick = (DUStorageDevice *)[[mbrDiscovery
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/scheme-mbr-lsblk-pairs.txt")
                              blkidOutput:@""] firstObject];
        PASS_EQUAL(stick.partitionScheme, @"mbr", "MBR disk");
        DUPartition *fat = (DUPartition *)stick.children.firstObject;
        PASS_EQUAL(fat.tableTypeCode, @"0x0C", "MBR type byte");
        PASS_EQUAL(fat.partitionUUID, @"eb9caa03-01", "MBR partition id");
        PASS(fat.name.length == 0, "MBR partitions have no name");

        /* An NVMe disk: GPT with an EFI System and a Linux partition. */
        NSArray *gptRoots = [[[[DULinuxDeviceDiscovery alloc] init]
            autorelease]
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/scheme-gpt-lsblk-pairs.txt")
                              blkidOutput:@""];
        DUStorageDevice *nvme = gptRoots.firstObject;
        PASS_EQUAL(nvme.partitionScheme, @"gpt", "GPT disk");
        DUPartition *esp = (DUPartition *)nvme.children[0];
        DUPartition *root = (DUPartition *)nvme.children[1];
        PASS_EQUAL(esp.tableTypeCode, @"c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
                   "ESP type GUID");
        PASS_EQUAL(root.tableTypeCode, @"0fc63daf-8483-4772-8e79-3d69d8477de4",
                   "Linux type GUID");
        PASS_EQUAL(esp.partitionUUID, @"35db470a-4384-4a27-b5ff-7b214e5815b8",
                   "ESP partition GUID");
        PASS_EQUAL(esp.name, @"primary", "GPT partition name");

        /* A filesystem straight on the disk. */
        DUStorageDevice *bare = (DUStorageDevice *)[[[[[DULinuxDeviceDiscovery alloc] init]
            autorelease]
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/scheme-none-lsblk-pairs.txt")
                              blkidOutput:@""] firstObject];
        PASS(bare.partitionScheme.length == 0, "no table, no scheme");
    END_SET("Partition scheme and types")

    START_SET("DataTraveler after Eject")
        /* Recorded after Eject: the stick is still plugged in, the kernel
         * keeps the disk but sees no medium (size 0, no partitions; blkid
         * finds nothing). The JSON next to the fixture is lsblk -J -O of
         * the same state, kept for reference. */
        NSArray *roots = Discover(@"datatraveler-ejected");
        PASS(roots.count == 1, "the ejected stick is still listed");
        DUStorageDevice *disk = roots.firstObject;
        PASS(disk.children.count == 0, "it shows no partitions");
        PASS(disk.mediumEjected, "the medium is ejected");
        PASS([disk.displayName rangeOfString:@"Ejected"].location
                 != NSNotFound,
             "the row says it is ejected");
        PASS(disk.capabilities.canMount == haveEject,
             "Mount is offered to bring it back");
        PASS(disk.capabilities.canVerify == haveEject &&
             disk.capabilities.canRestore == haveEject &&
             disk.capabilities.canCreateImage == haveEject,
             "commands that wake the disk first stay available");
        PASS(!disk.capabilities.canEject && !disk.capabilities.canUnmount &&
             !disk.capabilities.canPartition,
             "Eject, Unmount and Partition are off while ejected");
    END_SET("DataTraveler after Eject")

    START_SET("Unmount announcements")
        NSNotificationCenter *center =
            [[[NSNotificationCenter alloc] init] autorelease];
        NSMutableArray *seen = [NSMutableArray array];
        id observer = [center
            addObserverForName:nil
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            [seen addObject:@[ note.name, note.object ?: [NSNull null],
                               note.userInfo[@"NSDevicePath"] ?: @"" ]];
        }];
        [DULinuxUserMount postUnmountNotification:@"NSWorkspaceWillUnmountNotification"
                                       mountPoint:@"/media/admin/X"];
        PASS(seen.count == 0, "nothing is posted before a center is set");
        [DULinuxUserMount setWorkspaceNotificationCenter:center
                                                  sender:@"workspace"];
        [DULinuxUserMount postUnmountNotification:@"NSWorkspaceWillUnmountNotification"
                                       mountPoint:@"/media/admin/DATATRAVELE"];
        PASS_EQUAL(seen.lastObject,
                   (@[ @"NSWorkspaceWillUnmountNotification", @"workspace",
                       @"/media/admin/DATATRAVELE" ]),
                   "the unmount is announced with NSDevicePath = mount point");
        [DULinuxUserMount setWorkspaceNotificationCenter:nil sender:nil];
        [center removeObserver:observer];
    END_SET("Unmount announcements")

    START_SET("Mountable filesystems")
        PASS([DULinuxUserMount isMountableFilesystemType:@"vfat"] &&
             [DULinuxUserMount isMountableFilesystemType:@"ext4"],
             "FAT and ext4 mount");
        PASS(![DULinuxUserMount isMountableFilesystemType:@"crypto_LUKS"] &&
             ![DULinuxUserMount isMountableFilesystemType:@"LVM2_member"] &&
             ![DULinuxUserMount isMountableFilesystemType:@"swap"] &&
             ![DULinuxUserMount isMountableFilesystemType:@""],
             "containers, swap and unknown types do not");
    END_SET("Mountable filesystems")

    START_SET("Internal disk")
        DULinuxDeviceDiscovery *discovery =
            [[[DULinuxDeviceDiscovery alloc] init] autorelease];
        NSArray *roots = [discovery
            discoverObjectsFromLsblkPairs:
                TestFixtureNamed(@"Linux/lsblk-pairs.txt")
                              blkidOutput:TestFixtureNamed(@"Linux/blkid.txt")];
        DUStorageObject *disk = roots.firstObject;
        PASS_EQUAL(disk.backendPath, @"/dev/sda", "internal disk node");
        PASS(![DULinuxUserMount
                 isUserMountable:disk.children.firstObject],
             "udevil refuses internal disks, so they keep mount(8) as root");
        PASS(!disk.capabilities.canMount && !disk.capabilities.canEject,
             "an internal disk row keeps neither Mount nor Eject");
    END_SET("Internal disk")

    [arp release];
    return 0;
}

#else

int main(void)
{
    return 0;
}

#endif
