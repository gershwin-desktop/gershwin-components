/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// FAT16 and FAT32 as two explicit, user-visible formats. Everything that
// differs from one OS to the next lives here as pure functions so the
// backends only pick the tool and so one test suite covers all of them.
//
// Format identifiers are "fat32" and "fat16". Older identifiers for the
// undifferentiated family ("vfat", "fat", "msdos", "msdosfs") are accepted
// everywhere and mean FAT32, so stored choices keep working.
@interface DUFATFormat : NSObject

+ (NSString *)canonicalIdentifier:(NSString *)identifier;
+ (BOOL)isFATIdentifier:(NSString *)identifier;
+ (NSString *)displayNameForIdentifier:(NSString *)identifier;

// Smallest and largest target the tools build this type on; 0 means no
// bound. FAT16 stops at 2 GiB because the 64 KiB clusters needed above are
// not read by many systems.
+ (unsigned long long)minimumBytesForIdentifier:(NSString *)identifier;
+ (unsigned long long)maximumBytesForIdentifier:(NSString *)identifier;
// A size of 0 is "unknown" and never rules a format out.
+ (BOOL)identifier:(NSString *)identifier fitsBytes:(unsigned long long)bytes;

// Why a FAT type cannot be made on a target of this size, or nil when it
// can (or the identifier is not a FAT type). For the backends to refuse
// before they touch the target, so that a pane that missed the greying out
// still cannot destroy data and then fail.
+ (NSString *)sizeProblemForIdentifier:(NSString *)identifier
                                 bytes:(unsigned long long)bytes;

// {identifier, display name, can-format, min/max bytes} for FAT32 then FAT16.
+ (NSArray<NSDictionary *> *)formatDescriptorsToolAvailable:(BOOL)available;
// Applies the descriptor's min/max keys (if any) to a target size.
+ (BOOL)descriptor:(NSDictionary *)descriptor allowsBytes:(unsigned long long)bytes;

// Full argv (tool name first) for Linux mkfs.fat; nil for a non-FAT type.
+ (NSArray<NSString *> *)linuxMkfsArgumentsForIdentifier:(NSString *)identifier
                                                   label:(NSString *)label;
// Arguments before the device node for newfs_msdos, which FreeBSD, NextBSD,
// OpenBSD and NetBSD all call with -F <type> and -L <label>.
+ (NSArray<NSString *> *)newfsMsdosArgumentsForIdentifier:(NSString *)identifier
                                                    label:(NSString *)label;

// "fat12", "fat16" or "fat32" from a boot sector (at least 512 bytes), nil
// when it does not look like one. Uses the cluster count, which is how
// every FAT driver decides the type.
+ (NSString *)variantFromBootSector:(NSData *)sector;

@end
