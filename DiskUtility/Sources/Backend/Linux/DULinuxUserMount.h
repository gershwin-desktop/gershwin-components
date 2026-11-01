/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__linux__)

#import <Foundation/Foundation.h>

@class DUStorageObject;
@class DUStorageVolume;

// Mounting removable media as the logged-in user through udevil(1), the
// mounter of the devmon automounter that the Gershwin session starts. It is
// setuid root and needs no password; it mounts under /media/$USER/<label>
// with the user's uid/gid on FAT, so the files are writable by the user and
// the mount looks exactly like one devmon made when the stick was plugged
// in. udevil refuses internal disks to non-root users; those keep the
// privileged mount(8) path.
@interface DULinuxUserMount : NSObject

// Absolute path of udevil, or nil when it is not installed.
+ (NSString *)udevilPath;

// YES when the object lives on a disk that is not internal, i.e. one that
// udevil mounts for an ordinary user.
+ (BOOL)isUserMountable:(DUStorageObject *)object;

// Every volume at or below object, in tree order.
+ (NSArray<DUStorageVolume *> *)volumesOfObject:(DUStorageObject *)object;

// YES for filesystems the kernel mounts as files and folders; NO for swap,
// RAID/LVM/LUKS containers and anything unrecognized, which Mount on a
// whole disk has to skip.
+ (BOOL)isMountableFilesystemType:(NSString *)filesystemType;

// Where unmounts are announced. The desktop (Workspace) reports a volume
// that disappears unannounced as "removed without being properly ejected";
// the app hands in NSWorkspace's notification center and the workspace as
// sender, which reaches every application. Unset (tools, tests without
// it), nothing is posted.
+ (void)setWorkspaceNotificationCenter:(NSNotificationCenter *)center
                                sender:(id)sender;

// Posts name (NSWorkspaceWillUnmountNotification or ...DidUnmount...)
// with userInfo NSDevicePath = mountPoint on that center.
+ (void)postUnmountNotification:(NSString *)name
                     mountPoint:(NSString *)mountPoint;

// The mount point from udevil's "Mounted <device> at <directory>" line,
// or nil when the output does not name one for that device.
+ (NSString *)mountPointFromOutput:(NSString *)output
                            device:(NSString *)devicePath;

@end

#endif /* defined(__linux__) */
