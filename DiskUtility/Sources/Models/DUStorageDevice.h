/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

// SMART self-assessment result. Unknown until the backend queries it.
typedef NS_ENUM(NSInteger, DUStorageSmartStatus) {
    DUStorageSmartStatusUnknown = 0,
    DUStorageSmartStatusVerified,
    DUStorageSmartStatusFailing,
    DUStorageSmartStatusNotSupported,
};

// Physical or virtual storage device (ARCHITECTURE.md section 11).
@interface DUStorageDevice : DUStorageObject

@property (nonatomic, copy) NSString *devicePath;
@property (nonatomic, copy) NSString *connectionType; // e.g. "SATA", "USB"
@property (nonatomic) BOOL connectionIsInternal;
@property (nonatomic) unsigned long long capacityBytes;
@property (nonatomic) BOOL removable;
@property (nonatomic) BOOL readOnly;
@property (nonatomic) BOOL ejectable;

// Partition table scheme identifier: "gpt", "mbr", "bsd" or nil.
@property (nonatomic, copy) NSString *partitionScheme;

// YES when the partition table could not be READ (a failed or unavailable
// geom query), which is different from a disk that genuinely has no table.
// While set, the sidebar shows no partitions because none could be listed,
// and the destructive verbs stay off so the user is never invited to erase a
// disk whose contents are merely invisible.
@property (nonatomic) BOOL partitionTableUnreadable;

@property (nonatomic, copy) NSString *healthStatus;

// SMART self-assessment of the physical drive. Only meaningful for whole
// devices (disks), not volumes or partitions. The value is filled by the
// backend during discovery via +querySmartStatusForPath:.
@property (nonatomic) DUStorageSmartStatus smartStatus;

// Best-effort SMART self-assessment for a block device (smartctl). Returns
// DUStorageSmartStatusNotSupported when smartctl is absent or the device
// does not support SMART, so callers must cope with that value.
+ (DUStorageSmartStatus)querySmartStatusForPath:(NSString *)devicePath;

// Localized label for a DUStorageSmartStatus value.
+ (NSString *)localizedSmartStatus:(DUStorageSmartStatus)status;

// The Information panel's "Health Status:" row derived from the SMART verdict.
// nil when there is no verdict (Not Supported), so the row can be left blank
// instead of asserting a health claim that was never made.
+ (NSString *)healthStatusForSmartStatus:(DUStorageSmartStatus)status;

@property (nonatomic) BOOL optical;
// Only meaningful when optical is YES.
@property (nonatomic) BOOL mediaPresent;

- (instancetype)initWithIdentifier:(NSString *)identifier;

@end
