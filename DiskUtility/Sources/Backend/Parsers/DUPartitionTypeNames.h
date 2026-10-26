/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Display names for partition map schemes and table-level partition types,
// shared by all backends so the Info panel reads the same on every OS.
//
// A "type code" is the normalized, backend-neutral spelling of a partition's
// table type: "0x0C" for an MBR type byte, a lower-case GUID for GPT, or
// the raw token for tables that name types with words (BSD disklabel).
@interface DUPartitionTypeNames : NSObject

// Partition map scheme for a disk. Accepts the tokens lsblk, blkid, gpart
// and DUPartitionTableParser use ("gpt", "dos", "mac", "APM", ...). nil or
// empty means the disk has no table, shown as "None".
+ (NSString *)schemeDisplayName:(NSString *)schemeToken;

// "0x0C, FAT32 (LBA)" or "C12A7328-..., EFI System". A code without a known
// name is returned alone.
+ (NSString *)typeDisplayForCode:(NSString *)code;

// lsblk PARTTYPE column: "0xc" or a GUID in any case. nil when empty.
+ (NSString *)typeCodeFromLsblkPartType:(NSString *)raw;

// gpart/geom "rawtype" (decimal MBR byte, GUID, or absent) with the
// "type" token as the fallback for tables that have no raw type.
+ (NSString *)typeCodeFromGeomRawType:(NSString *)rawType
                                 type:(NSString *)typeToken;

@end
