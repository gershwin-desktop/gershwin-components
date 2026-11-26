/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

@class DUStorageVolume;

// Partition-table entry (ARCHITECTURE.md section 12).
@interface DUPartition : DUStorageObject <NSCopying>

@property (nonatomic) NSInteger index;
@property (nonatomic) unsigned long long offsetBytes;
@property (nonatomic) unsigned long long sizeBytes;

// Raw table-level type string as reported by the backend.
@property (nonatomic, copy) NSString *partitionType;

// Normalized table-level type, as DUPartitionTypeNames spells it: "0x0C"
// (MBR), a lower-case GUID (GPT) or a type word (BSD disklabel). nil when
// the backend cannot tell. partitionType above is not reliable for this:
// some backends keep a filesystem token in it.
@property (nonatomic, copy) NSString *tableTypeCode;

// Partition GUID (GPT) or table-assigned id (MBR); nil when none.
@property (nonatomic, copy) NSString *partitionUUID;

// Label/name from the partition table ("partitionName" in section 12);
// not localized, may be nil.
@property (nonatomic, copy) NSString *name;

@property (nonatomic, copy) NSString *filesystemType; // e.g. "ext4" or nil
@property (nonatomic) BOOL bootable;
@property (nonatomic) BOOL readOnly;

// Filesystem contained in this partition; nil while unknown/unformatted.
@property (nonatomic, strong) DUStorageVolume *volume;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
