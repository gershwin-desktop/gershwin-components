/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUPartition;
@class DUPartitionLayout;
@class DUStorageObject;

// Immutable description of a partitioning operation (ARCHITECTURE.md
// section 87). The backend receives this validated snapshot instead of
// loosely related UI values.
@interface DUPartitionPlan : NSObject

@property (nonatomic, copy, readonly) NSString *diskIdentifier;
@property (nonatomic, copy, readonly) NSString *scheme;

// Deep-copied snapshot of the layout's partitions at plan time.
@property (nonatomic, copy, readonly) NSArray<DUPartition *> *entries;

@property (nonatomic, readonly) BOOL destructive;
// Partition table edits always run privileged.
@property (nonatomic, readonly) BOOL requiresPrivilege;

// Set by the operation that carries the plan; the backend polls it so Stop
// can end a long format instead of waiting for it.
@property (nonatomic, copy) BOOL (^cancelCheck)(void);

// Plan for erasing a whole disk the way users expect: a fresh partition
// table with one partition spanning the disk, formatted as asked. FAT gets
// an MBR table for the widest device support, everything else GPT. nil with
// error set when the disk is too small to hold a table and a partition.
+ (instancetype)planForWholeDiskErase:(DUStorageObject *)disk
                           filesystem:(NSString *)filesystemType
                                 name:(NSString *)name
                                error:(NSError **)error;

+ (instancetype)planFromLayout:(DUPartitionLayout *)layout
                    forDevice:(DUStorageObject *)device
                   destructive:(BOOL)destructive;


@end
