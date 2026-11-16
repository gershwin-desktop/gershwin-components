/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import "DULinuxUserMount.h"

#import "DUProcessRunner.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

static NSNotificationCenter *gWorkspaceCenter = nil;
static id gWorkspaceSender = nil;

@implementation DULinuxUserMount

+ (void)setWorkspaceNotificationCenter:(NSNotificationCenter *)center
                                sender:(id)sender
{
    @synchronized(self) {
        gWorkspaceCenter = center;
        gWorkspaceSender = sender;
    }
}

+ (void)postUnmountNotification:(NSString *)name
                     mountPoint:(NSString *)mountPoint
{
    NSNotificationCenter *center = nil;
    id sender = nil;
    @synchronized(self) {
        center = gWorkspaceCenter;
        sender = gWorkspaceSender;
    }
    if (center == nil || mountPoint.length == 0) {
        return;
    }
    [center postNotificationName:name
                          object:sender
                        userInfo:@{ @"NSDevicePath" : mountPoint }];
}

+ (NSString *)udevilPath
{
    return [DUProcessRunner executablePathForName:@"udevil"];
}

+ (BOOL)isUserMountable:(DUStorageObject *)object
{
    DUStorageObject *root = object;
    while (root.parent != nil) {
        root = root.parent;
    }
    if (![root isKindOfClass:[DUStorageDevice class]]) {
        return NO;
    }
    return !((DUStorageDevice *)root).connectionIsInternal;
}

+ (NSArray<DUStorageVolume *> *)volumesOfObject:(DUStorageObject *)object
{
    NSMutableArray<DUStorageVolume *> *volumes = [NSMutableArray array];
    // Iterative pre-order walk; a recursive block would retain itself.
    NSMutableArray<DUStorageObject *> *work =
        [NSMutableArray arrayWithObject:object];
    while (work.count > 0) {
        DUStorageObject *next = work.lastObject;
        [work removeLastObject];
        if ([next isKindOfClass:[DUStorageVolume class]]) {
            [volumes addObject:(DUStorageVolume *)next];
        }
        for (DUStorageObject *child in
                 [next.children reverseObjectEnumerator]) {
            [work addObject:child];
        }
    }
    return volumes;
}

+ (BOOL)isMountableFilesystemType:(NSString *)filesystemType
{
    NSSet<NSString *> *mountable = [NSSet setWithArray:@[
        @"vfat", @"msdos", @"exfat", @"ntfs", @"ntfs3",
        @"ext2", @"ext3", @"ext4", @"xfs", @"f2fs",
        @"hfs", @"hfsplus", @"iso9660", @"udf",
    ]];
    return filesystemType.length > 0 && [mountable containsObject:filesystemType];
}

+ (NSString *)mountPointFromOutput:(NSString *)output
                            device:(NSString *)devicePath
{
    // DUProcessRunner runs tools with LC_ALL=C, so the line is English.
    NSString *prefix =
        [NSString stringWithFormat:@"Mounted %@ at ", devicePath];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:
                                       [NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:prefix] && line.length > prefix.length) {
            return [line substringFromIndex:prefix.length];
        }
    }
    return nil;
}

@end

#endif /* defined(__linux__) */
