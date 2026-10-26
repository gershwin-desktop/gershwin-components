/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Live mount/unmount/eject exercise of the Linux backend on a loop device
 * the caller prepared (partition 1 FAT32, 2 ext4, 3 swap, 4 empty):
 *
 *   ./obj/t_LiveMount /dev/loopN
 *
 * and Eject followed by Mount on a removable scsi_debug disk (partition 1
 * FAT32, 2 ext4), which goes through udevil and eject(1) like a USB stick:
 *
 *   sudo modprobe scsi_debug removable=1 dev_size_mb=64 num_parts=2
 *   ./obj/t_LiveMount --scsi-debug /dev/sdX
 *
 * Run as the user, like the app. Loop devices count as internal, so this
 * covers the mount(8)/umount(8)-as-root path; udevil refuses them. The app
 * hides loop devices, so the lsblk rows are replayed with the loop row
 * presented as a disk. The node is checked to be a loop device first. */

#import <Foundation/Foundation.h>

#if defined(__linux__)

#import <fcntl.h>
#import <unistd.h>

#import "DUErrors.h"
#import "DULinuxFilesystemTool.h"
#import "DULinuxDeviceDiscovery.h"
#import "DULinuxStorageBackend.h"
#import "DULinuxUserMount.h"
#import "DUProcessRunner.h"
#import "DUStorageDevice.h"
#import "DUStorageVolume.h"

static int gFailed = 0;
static int gPassed = 0;

static void Check(BOOL ok, NSString *what)
{
    if (ok) {
        gPassed++;
        printf("  ok   %s\n", what.UTF8String);
    } else {
        gFailed++;
        printf("  FAIL %s\n", what.UTF8String);
    }
}

static DUStorageDevice *Discover(NSString *device)
{
    DUProcessResult *lsblk = [DUProcessRunner
        runExecutable:[DUProcessRunner executablePathForName:@"lsblk"]
            arguments:@[ @"-P", @"-b", @"-o",
                         @"NAME,PKNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL,PARTUUID,UUID,MODEL,RO,RM,HOTPLUG,MAJ:MIN",
                         device ]
                error:NULL];
    NSString *rows = [lsblk.standardOutput
        stringByReplacingOccurrencesOfString:@"TYPE=\"loop\""
                                  withString:@"TYPE=\"disk\""];
    NSArray *roots = [[[DULinuxDeviceDiscovery alloc] init]
        discoverObjectsFromLsblkPairs:rows
                          blkidOutput:@""];
    return roots.count == 1 ? roots.firstObject : nil;
}

static NSString *MountTable(void)
{
    return [NSString stringWithContentsOfFile:@"/proc/self/mounts"
                                     encoding:NSUTF8StringEncoding
                                        error:NULL];
}

static BOOL IsMounted(NSString *node)
{
    return [MountTable() rangeOfString:[node stringByAppendingString:@" "]]
               .location != NSNotFound;
}

static NSError *Wait(void (^start)(void (^done)(NSError *)))
{
    NSCondition *condition = [[NSCondition alloc] init];
    __block BOOL finished = NO;
    __block NSError *result = nil;
    start(^(NSError *error) {
        [condition lock];
        result = error;
        finished = YES;
        [condition signal];
        [condition unlock];
    });
    [condition lock];
    while (!finished) {
        [condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:300]];
    }
    [condition unlock];
    return result;
}

// What the desktop would hear: (name, mount point) per announcement.
static NSMutableArray<NSArray *> *gAnnouncements = nil;

static void ListenForAnnouncements(void)
{
    NSNotificationCenter *center = [[NSNotificationCenter alloc] init];
    gAnnouncements = [NSMutableArray array];
    [center addObserverForName:nil
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        @synchronized(gAnnouncements) {
            [gAnnouncements addObject:@[
                [note.name hasPrefix:@"NSWorkspaceWill"] ? @"will" : @"did",
                note.userInfo[@"NSDevicePath"] ?: @"" ]];
        }
    }];
    [DULinuxUserMount setWorkspaceNotificationCenter:center sender:nil];
}

static NSString *Announced(void)
{
    @synchronized(gAnnouncements) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSArray *entry in gAnnouncements) {
            [parts addObject:[NSString stringWithFormat:@"%@ %@",
                                 entry[0], [entry[1] lastPathComponent]]];
        }
        [gAnnouncements removeAllObjects];
        return [parts componentsJoinedByString:@", "];
    }
}

static DUStorageDevice *DiscoverDisk(NSString *identifier)
{
    for (DUStorageObject *root in
             [[[DULinuxDeviceDiscovery alloc] init] discoverObjects:NULL]) {
        if ([root.identifier isEqualToString:identifier]) {
            return (DUStorageDevice *)root;
        }
    }
    return nil;
}

static int RunScsiDebug(NSString *device)
{
    NSString *name = device.lastPathComponent;
    NSString *model = [[NSString stringWithContentsOfFile:
        [NSString stringWithFormat:@"/sys/block/%@/device/model", name]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![model isEqualToString:@"scsi_debug"]) {
        fprintf(stderr, "%s is not a scsi_debug disk\n", device.UTF8String);
        return 2;
    }
    NSString *identifier = [@"linux-disk-" stringByAppendingString:name];
    NSString *p1 = [device stringByAppendingString:@"1"];
    NSString *p2 = [device stringByAppendingString:@"2"];
    DULinuxStorageBackend *backend = [[DULinuxStorageBackend alloc] init];

    DUStorageDevice *disk = DiscoverDisk(identifier);
    Check(disk != nil && !disk.connectionIsInternal &&
          disk.capabilities.canMount && disk.capabilities.canEject,
          @"the removable disk offers Mount and Eject");
    NSError *error = Wait(^(void (^done)(NSError *)) {
        [backend mountObject:disk
                  completion:^(NSError *e, NSString *m) {
            (void)m;
            done(e);
        }];
    });
    Check(error == nil && IsMounted(p1) && IsMounted(p2),
          [NSString stringWithFormat:@"Mount mounts both volumes as the user (%@)",
              error.userInfo[kDUBackendDetailKey] ?: @"ok"]);

    disk = DiscoverDisk(identifier);
    NSArray *points = [[DULinuxUserMount volumesOfObject:disk]
        valueForKey:@"mountPoint"];
    Announced();
    error = Wait(^(void (^done)(NSError *)) {
        [backend ejectObject:disk.children.firstObject completion:done];
    });
    Check(error == nil && !IsMounted(p1) && !IsMounted(p2),
          [NSString stringWithFormat:@"Eject unmounts both and ejects (%@)",
              error.localizedDescription ?: @"ok"]);
    NSString *expected = [NSString stringWithFormat:
        @"will %@, did %@, will %@, did %@",
        [points[0] lastPathComponent], [points[0] lastPathComponent],
        [points[1] lastPathComponent], [points[1] lastPathComponent]];
    NSString *announced = Announced();
    Check([announced isEqualToString:expected],
          [NSString stringWithFormat:
              @"each unmount is announced before and after (%@)", announced]);

    /* scsi_debug keeps its size after a stop, where a USB stick drops to 0;
     * the row is marked the way discovery shows an ejected stick, so the
     * shared start path runs against a really stopped unit. */
    disk = DiscoverDisk(identifier);
    disk.mediumEjected = YES;
    NSError *startError = nil;
    BOOL started = [backend startMediumOfObject:disk error:&startError];
    Check(started, [NSString stringWithFormat:
              @"the ejected disk is started again (%@ %@)",
              startError.localizedDescription ?: @"ok",
              startError.userInfo[kDUBackendDetailKey] ?: @""]);
    disk = DiscoverDisk(identifier);
    error = Wait(^(void (^done)(NSError *)) {
        [backend mountObject:disk
                  completion:^(NSError *e, NSString *m) {
            (void)m;
            done(e);
        }];
    });
    Check(error == nil && IsMounted(p1) && IsMounted(p2),
          [NSString stringWithFormat:
              @"Mount on the ejected disk starts it and mounts both (%@ %@)",
              error.localizedDescription ?: @"ok",
              error.userInfo[kDUBackendDetailKey] ?: @""]);

    disk = DiscoverDisk(identifier);
    error = Wait(^(void (^done)(NSError *)) {
        [backend unmountObject:disk completion:done];
    });
    Check(error == nil && !IsMounted(p1) && !IsMounted(p2),
          @"Unmount on the disk leaves nothing mounted");
    printf("== summary == %d passed, %d failed\n", gPassed, gFailed);
    return gFailed == 0 ? 0 : 1;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        ListenForAnnouncements();
        if (argc == 3 && strcmp(argv[1], "--scsi-debug") == 0) {
            return RunScsiDebug(@(argv[2]));
        }
        NSString *device = argc == 2 ? @(argv[1]) : nil;
        NSRegularExpression *loop = [NSRegularExpression
            regularExpressionWithPattern:@"^/dev/loop[0-9]+$"
                                 options:0
                                   error:NULL];
        if (device == nil ||
            [loop numberOfMatchesInString:device
                                  options:0
                                    range:NSMakeRange(0, device.length)] != 1) {
            fprintf(stderr, "usage: t_LiveMount /dev/loopN\n");
            return 2;
        }
        NSString *p1 = [device stringByAppendingString:@"p1"];
        NSString *p2 = [device stringByAppendingString:@"p2"];
        NSString *p3 = [device stringByAppendingString:@"p3"];
        DULinuxStorageBackend *backend = [[DULinuxStorageBackend alloc] init];

        DUStorageDevice *disk = Discover(device);
        Check([DULinuxUserMount volumesOfObject:disk].count == 2,
              @"FAT32 and ext4 carry volumes, swap and empty do not");

        NSError *error = Wait(^(void (^done)(NSError *)) {
            [backend mountObject:disk
                      completion:^(NSError *e, NSString *m) {
                (void)m;
                done(e);
            }];
        });
        Check(error == nil, @"Mount on the disk succeeds");
        Check(IsMounted(p1) && IsMounted(p2) && !IsMounted(p3),
              @"it mounted FAT32 and ext4, and left swap alone");

        disk = Discover(device);
        error = Wait(^(void (^done)(NSError *)) {
            [backend unmountObject:disk completion:done];
        });
        Check(error == nil && !IsMounted(p1) && !IsMounted(p2),
              @"Unmount on the disk unmounts both");

        disk = Discover(device);
        Wait(^(void (^done)(NSError *)) {
            [backend mountObject:disk
                      completion:^(NSError *e, NSString *m) {
                (void)m;
                done(e);
            }];
        });
        disk = Discover(device);
        DUStorageVolume *ext4 = [DULinuxUserMount volumesOfObject:disk][1];
        int holder = open(ext4.mountPoint.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY);
        Check(holder >= 0, @"a directory on the ext4 volume is held open");
        if (holder >= 0) {
            chdir(ext4.mountPoint.fileSystemRepresentation);
        }
        DUStorageObject *fatPartition = disk.children[0];
        Announced();
        error = Wait(^(void (^done)(NSError *)) {
            [backend ejectObject:fatPartition completion:done];
        });
        chdir("/");
        if (holder >= 0) {
            close(holder);
        }
        Check(error.code == DUErrorDeviceBusy &&
              [error.localizedDescription rangeOfString:@"LINUXDATA"].location
                  != NSNotFound,
              [NSString stringWithFormat:
                  @"Eject reports the busy volume by name (%@)",
                  error.localizedDescription]);
        Check(!IsMounted(p1) && IsMounted(p2),
              @"it stopped at the busy volume and did not eject");
        NSString *announced = Announced();
        NSArray *steps = [announced componentsSeparatedByString:@", "];
        Check(steps.count == 3 && [steps[0] hasPrefix:@"will DATATRAVELE"] &&
              [steps[1] hasPrefix:@"did DATATRAVELE"] &&
              [steps[2] hasPrefix:@"will LINUXDATA"],
              [NSString stringWithFormat:
                  @"the busy volume is announced but not reported unmounted "
                  @"(%@)", announced]);

        disk = Discover(device);
        error = Wait(^(void (^done)(NSError *)) {
            [backend ejectObject:disk completion:done];
        });
        Check(!IsMounted(p1) && !IsMounted(p2),
              @"Eject unmounts every volume before ejecting");
        // A loop device has no medium to eject, so eject(1) refuses here;
        // on a USB disk this is the step that stops the drive.
        Check([error.localizedDescription
                  isEqualToString:@"The media could not be ejected."],
              [NSString stringWithFormat:@"eject(1) was reached (%@)",
                  error.localizedDescription ?: @"no error"]);

        printf("== summary == %d passed, %d failed\n", gPassed, gFailed);
    }
    return gFailed == 0 ? 0 : 1;
}

#else

int main(void)
{
    return 0;
}

#endif
