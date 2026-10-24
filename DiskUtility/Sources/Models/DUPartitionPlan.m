/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionPlan.h"

#import "DUPartition.h"
#import "DUPartitionLayout.h"
#import "DUErrors.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"

@implementation DUPartitionPlan {
    NSString *_diskIdentifier;
    NSString *_scheme;
    NSArray<DUPartition *> *_entries;
    BOOL _destructive;
}

+ (instancetype)planForWholeDiskErase:(DUStorageObject *)disk
                           filesystem:(NSString *)filesystemType
                                 name:(NSString *)name
                                error:(NSError **)error
{
    // The first MiB is skipped for alignment and the last one is left for
    // the backup table, so the partition spans everything in between.
    static const unsigned long long kMargin = 2ULL * 1024 * 1024;
    unsigned long long capacity =
        [disk isKindOfClass:[DUStorageDevice class]]
            ? ((DUStorageDevice *)disk).capacityBytes : 0;
    if (capacity < kMargin + 2ULL * 1024 * 1024) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorInvalidArgument,
                                 NSLocalizedString(@"The disk is too small "
                                                   @"to hold a partition "
                                                   @"table.", nil));
        }
        return nil;
    }
    NSString *scheme =
        [filesystemType isEqualToString:@"vfat"] ||
        [filesystemType isEqualToString:@"fat32"] ? @"mbr" : @"gpt";
    DUPartitionLayout *layout =
        [[DUPartitionLayout alloc] initWithCapacity:capacity scheme:scheme];
    if (![layout addPartitionWithSize:capacity - kMargin
                                 name:name
                                error:error]) {
        return nil;
    }
    [layout setFormat:filesystemType forPartition:layout.partitions[0]];
    return [self planFromLayout:layout forDevice:disk destructive:YES];
}

+ (instancetype)planFromLayout:(DUPartitionLayout *)layout
                    forDevice:(DUStorageObject *)device
                   destructive:(BOOL)destructive
{
    NSParameterAssert(layout != nil);
    NSParameterAssert(device != nil);
    NSParameterAssert(device.identifier.length > 0);
    // A plan is only made from a valid layout; validation happens before
    // Apply per ARCHITECTURE.md sections 43/44, so an invalid layout here
    // is a caller bug and must fail loudly rather than reach a backend.
    NSError *validationError = nil;
    if (![layout validate:&validationError]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Cannot build partition plan from invalid "
                           @"layout: %@",
                           validationError.localizedDescription];
    }

    NSMutableArray<DUPartition *> *snapshot =
        [NSMutableArray arrayWithCapacity:layout.partitions.count];
    for (DUPartition *partition in layout.partitions) {
        [snapshot addObject:[partition copy]];
    }

    return [[self alloc] _initWithDiskIdentifier:device.identifier
                                          scheme:layout.scheme
                                         entries:snapshot
                                      destructive:destructive];
}

- (instancetype)_initWithDiskIdentifier:(NSString *)diskIdentifier
                                 scheme:(NSString *)scheme
                                entries:(NSArray<DUPartition *> *)entries
                             destructive:(BOOL)destructive
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _diskIdentifier = [diskIdentifier copy];
    _scheme = [scheme copy];
    _entries = [entries copy];
    _destructive = destructive;
    return self;
}

// Table edits always run privileged, regardless of the destructive flag
// (header contract).
- (BOOL)requiresPrivilege
{
    return YES;
}

@end
