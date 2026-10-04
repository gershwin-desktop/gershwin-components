/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import "DUFreeBSDStorageBackend.h"
#import "DURepairPermissionsTool.h"

#import <sys/statvfs.h>
#import <sys/wait.h>

#import "DUBackendCapabilities.h"
#import "DUErrors.h"
#import "DUFreeBSDDeviceDiscovery.h"
#import "DUFreeBSDGEOMAdapter.h"
#import "DUDiskImage.h"
#import "DUOpticalMedia.h"
#import "DUPartition.h"
#import "DUPartitionPlan.h"
#import "DUPartitionTableParser.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"
#import "DUAuthorizationManager.h"
#import "DUStorageCapabilities.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

// UFS volume labels are capped by newfs itself (MAXLABELLEN 15); FAT has
// the classic 11-character limit. Truncate before the tool rejects them.
static const NSUInteger kMaxUFSLabelLength = 15;
static const NSUInteger kMaxFATLabelLength = 11;

/* Whether a bare device name is a whole disk rather than one of its
 * partitions or slices.
 *
 * FreeBSD disk names are letters followed by digits: "ada0", "da12",
 * "nvme0", "mmcsd0", "nvd0", "md0", "nda0", "vtbd0". Partition and slice
 * names append a letter and more digits after that: "ada0p2", "ada0s1a",
 * "mmcsd0p2".
 *
 * NVMe namespace names are the one shape that does not fit that rule:
 * "nvme0n1" is a whole disk, and the "n" between the two digit runs is
 * what a naive trailing-digit scan trips over. Both forms are matched
 * explicitly rather than with a digit-stripping heuristic, so the
 * busy-guard cannot miss an NVMe disk or mistake a partition for one. */
static BOOL IsWholeDiskNodeName(NSString *name)
{
    if (name.length == 0) {
        return NO;
    }
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSUInteger i = 0;
    while (i < name.length &&
           [letters characterIsMember:[name characterAtIndex:i]]) {
        i++;
    }
    if (i == 0 || i == name.length) {
        return NO;
    }
    NSUInteger firstDigit = i;
    while (i < name.length &&
           [digits characterIsMember:[name characterAtIndex:i]]) {
        i++;
    }
    if (i == firstDigit) {
        return NO;
    }
    if (i == name.length) {
        return YES;  // da0, nvd0, mmcsd0
    }
    // A letter after the digit run starts a partition or slice name, except
    // for the "nvme<N>n<M>" namespace form, which repeats digits afterwards.
    if (i + 1 >= name.length ||
        [name characterAtIndex:i] != 'n') {
        return NO;
    }
    NSUInteger j = i + 1;
    if (j >= name.length ||
        ![digits characterIsMember:[name characterAtIndex:j]]) {
        return NO;
    }
    while (j < name.length &&
           [digits characterIsMember:[name characterAtIndex:j]]) {
        j++;
    }
    return j == name.length;
}

/* Whether a device node name belongs to a partition or slice of the given
 * whole-disk name. "da1" owns "da1p2" and "da1s1a" but not "da10p2", so a
 * bare hasPrefix: would report a neighbouring disk as a child. */
static BOOL IsNodeOnDisk(NSString *nodeName, NSString *diskName)
{
    if (![nodeName hasPrefix:diskName] || nodeName.length <= diskName.length) {
        return NO;
    }
    unichar separator = [nodeName characterAtIndex:diskName.length];
    return separator == 'p' || separator == 's';
}

@implementation DUFreeBSDStorageBackend

- (NSArray<NSString *> *)expectedToolNames
{
    return @[
        @"geom", @"mount", @"umount", @"gpart", @"newfs", @"newfs_msdos",
        @"fsck_ffs", @"fsck_msdosfs", @"dd", @"gmirror", @"gstripe",
        @"gconcat", @"sha256", @"gzip", @"qemu-img", @"cdrecord", @"wodim",
        @"xorriso", @"growisofs", @"eject", @"camcontrol", @"cat"
    ];
}

// Without these the app cannot read the disk list, check, format, mount or
// write an image, so the startup check treats them as blocking. Everything
// else the backend mentions is optional: the geom RAID classes, the
// qemu-img image formats, the cdrecord-family burners, and the eject tools
// each gate exactly one menu item and are already reported per-feature in
// the capabilities report.
- (NSArray<NSString *> *)requiredToolNames
{
    return @[
        @"geom", @"mount", @"umount", @"gpart", @"newfs", @"newfs_msdos",
        @"fsck_ffs", @"fsck_msdosfs", @"dd", @"sha256", @"gzip",
    ];
}

#pragma mark - Discovery and capability reporting

- (NSArray *)discoverStorageObjects:(NSError **)error
{
    NSMutableArray *objects =
        [[[DUFreeBSDDeviceDiscovery alloc] discoverObjects:error]
            mutableCopy];
    // Registered disk-image files (user default, ARCHITECTURE.md section 67)
    // become roots so convert/resize can target them. Format probing and
    // capability gating both depend on qemu-img being present.
    [objects addObjectsFromArray:[self discoverRegisteredImages]];
    return objects;
}

// The user registers image paths through the DUAdditionalImages default; we
// surface each as a DUDiskImage root. Without qemu-img neither conversion nor
// resizing is possible, so both capabilities stay off and the toolbar
// Convert/Resize buttons disable themselves honestly.
- (NSArray<DUDiskImage *> *)discoverRegisteredImages
{
    NSArray<NSString *> *imagePaths =
        [[NSUserDefaults standardUserDefaults]
            arrayForKey:@"DUAdditionalImages"] ?: @[];
    BOOL qemuImg = [DUFreeBSDToolCache haveTool:@"qemu-img"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<DUDiskImage *> *images = [NSMutableArray array];
    for (NSString *path in imagePaths) {
        if (![fileManager fileExistsAtPath:path]) {
            continue;
        }
        DUDiskImage *image = [[DUDiskImage alloc]
            initWithIdentifier:[@"freebsd-image-"
                                    stringByAppendingString:
                                        [path stringByAddingPercentEncodingWithAllowedCharacters:
                                                  [NSCharacterSet alphanumericCharacterSet]].lowercaseString]];
        image.displayName = path.lastPathComponent;
        image.path = path;
        NSDictionary<NSString *, NSNumber *> *attributes =
            [fileManager attributesOfItemAtPath:path error:NULL];
        image.sizeBytes =
            attributes[NSFileSize].unsignedLongLongValue;
        image.encrypted = NO;
        image.compressed = NO;
        image.mounted = NO;
        image.capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
        // Image mounting on FreeBSD needs mdconfig; that path is not wired
        // here, so only expose convert/resize which qemu-img handles.
        image.capabilities.canConvertImage = qemuImg;
        image.capabilities.canResizeImage = qemuImg;
        [images addObject:image];
    }
    return images;
}

- (NSDictionary *)capabilitiesReport
{
    // Flags reflect installed tools so the diagnostics page shows honest
    // answers instead of a flat "everything works" on minimal systems.
    DUBackendReport *report = [[DUBackendReport alloc] init];
    report.discovery = [DUFreeBSDToolCache haveTool:@"geom"];
    report.mountManagement =
        [DUFreeBSDToolCache haveTool:@"mount"] &&
        [DUFreeBSDToolCache haveTool:@"umount"];
    report.partitioning = [DUFreeBSDToolCache haveTool:@"gpart"];
    report.filesystemFormat =
        [DUFreeBSDToolCache haveTool:@"newfs"] ||
        [DUFreeBSDToolCache haveTool:@"newfs_msdos"];
    report.filesystemRepair =
        [DUFreeBSDToolCache haveTool:@"fsck_ffs"] ||
        [DUFreeBSDToolCache haveTool:@"fsck_msdosfs"];
    report.secureErase = [DUFreeBSDToolCache haveTool:@"dd"];
    report.raidManagement =
        [DUFreeBSDToolCache haveTool:@"gmirror"] ||
        [DUFreeBSDToolCache haveTool:@"gstripe"] ||
        [DUFreeBSDToolCache haveTool:@"gconcat"];
    // Image creation ends in a mandatory SHA-256 comparison of source and
    // written bytes; advertising it without a hasher would turn every copy
    // into a guaranteed late checksum failure.
    report.imageCreate =
        [DUFreeBSDToolCache haveTool:@"dd"] &&
        [DUFreeBSDToolCache haveAnyTool:@[ @"sha256", @"sha256sum" ]];
    // Image conversion and resizing are performed through qemu-img, run as
    // a separate GPL process per LIBRARIES.md section 3 (never linked or
    // dlopen'd). Burning uses a GPL cdrecord-family tool out of process
    // (LIBRARIES.md section 26) - no burn support means no capability.
    BOOL qemuImg = [DUFreeBSDToolCache haveTool:@"qemu-img"];
    report.imageConvert = qemuImg;
    report.imageResize = qemuImg;
    report.burn = [self burnToolPath] != nil;
    return [report reportDictionary];
}

#pragma mark - Format descriptors

- (NSArray<NSDictionary *> *)supportedFormatsForObject:(DUStorageObject *)object
{
    if (object == nil || object.capabilities.canErase == NO) {
        return @[];
    }
    BOOL ufsPossible = [DUFreeBSDToolCache haveTool:@"newfs"];
    BOOL fatPossible = [DUFreeBSDToolCache haveTool:@"newfs_msdos"];

    NSMutableArray<NSDictionary *> *formats = [NSMutableArray array];
    [formats addObject:@{
        kDUFormatIdentifierKey : @"ufs",
        kDUFormatDisplayNameKey :
            [DUPartitionTableParser filesystemDisplayName:@"ufs"],
        kDUFormatCanFormatKey : @(ufsPossible),
    }];
    [formats addObject:@{
        kDUFormatIdentifierKey : @"fat32",
        kDUFormatDisplayNameKey :
            [DUPartitionTableParser filesystemDisplayName:@"vfat"],
        kDUFormatCanFormatKey : @(fatPossible),
    }];
    // Swap partitions are marked in the table, not formatted by a tool, so
    // the entry exists for planning but honestly reports cannot-format.
    [formats addObject:@{
        kDUFormatIdentifierKey : @"swap",
        kDUFormatDisplayNameKey :
            [DUPartitionTableParser filesystemDisplayName:@"swap"],
        kDUFormatCanFormatKey : @NO,
    }];
    return formats;
}

#pragma mark - Operation gating

- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object
{
    if (op == nil || object == nil || object.capabilities == nil) {
        return NO;
    }
    DUStorageCapabilities *caps = object.capabilities;

    if ([op isEqualToString:kDUOperationVerify]) return caps.canVerify;
    if ([op isEqualToString:kDUOperationRepair]) return caps.canRepair;
    if ([op isEqualToString:kDUOperationErase]) return caps.canErase;
    if ([op isEqualToString:kDUOperationPartition]) return caps.canPartition;
    if ([op isEqualToString:kDUOperationMount]) return caps.canMount;
    if ([op isEqualToString:kDUOperationUnmount]) return caps.canUnmount;
    if ([op isEqualToString:kDUOperationEject]) return caps.canEject;
    if ([op isEqualToString:kDUOperationRestore]) return caps.canRestore;
    if ([op isEqualToString:kDUOperationBurn]) return caps.canBurn;
    if ([op isEqualToString:kDUOperationCreateImage]) return caps.canCreateImage;
    if ([op isEqualToString:kDUOperationConvertImage]) return caps.canConvertImage;
    if ([op isEqualToString:kDUOperationResizeImage]) return caps.canResizeImage;
    if ([op isEqualToString:kDUOperationToggleJournaling]) return caps.canToggleJournaling;
    return NO;
}

// Whether a partition table currently exists on the node. Asked with
// `gpart show` rather than inferred from a failed `gpart destroy`: the
// wording of "no table here" differs between gpart builds ("No such geom:
// da1" on some, "arg0 'da1': Invalid argument" on this one), and both
// spellings would otherwise be read as a failure to remove a table that
// never existed - which is exactly what partitioning an unlabelled disk
// needs to do.
- (BOOL)partitionTableExistsOn:(NSString *)nodeName
                     gpartPath:(NSString *)gpartPath
{
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager]
            runPrivileged:gpartPath
                     args:@[ @"show", nodeName ]
                  timeout:120.0
                    error:NULL];
    if ([self runSucceeded:result]) {
        return YES;
    }
    NSString *complaint = [NSString
        stringWithFormat:@"%@ %@", result.standardError,
                          result.standardOutput];
    return !([DUParsing caseInsensitiveContains:complaint
                                       needle:@"no such geom"] ||
             [DUParsing caseInsensitiveContains:complaint
                                       needle:@"invalid argument"] ||
             [DUParsing caseInsensitiveContains:complaint
                                       needle:@"no space"]);
}

- (NSError *)gateForOperation:(NSString *)op onObject:(DUStorageObject *)object
{
    if (object == nil) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No object selected.", nil));
    }
    if (![self supportsOperation:op forObject:object]) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"\"%@\" cannot be performed on %@.", nil),
             op,
             object.displayName ?: NSLocalizedString(@"this item", nil)]);
    }
    return nil;
}

#pragma mark - Worker plumbing

// Documented async contract: work runs on a private thread with an
// autorelease pool; progress and completion fire there or on reader threads
// spawned below, and callers marshal to main themselves.
- (void)spawnWork:(void (^)(void))work
{
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            work();
        }
    }];
    worker.name = @"DU FreeBSD op";
    [worker start];
}

// Streams a tool run while the calling worker blocks until completion, so
// the operation's completion callback fires on that worker as promised.
// The tool runs elevated (sudo -A askpass when not root) because every
// caller here reads or writes raw device nodes.
- (DUProcessResult *)blockingStreamedRun:(NSString *)path
                               arguments:(NSArray<NSString *> *)arguments
                             lineHandler:(void (^)(NSString *line))lineHandler
{
    NSCondition *condition = [[NSCondition alloc] init];
    __block DUProcessResult *result = nil;
    __block BOOL finished = NO;
    NSError *streamError = nil;

    [[DUAuthorizationManager sharedManager]
        streamPrivileged:path
                    args:arguments
           stdoutHandler:lineHandler
            finishHandler:^(DUProcessResult *runResult) {
                [condition lock];
                result = runResult;
                finished = YES;
                [condition signal];
                [condition unlock];
            }
                    error:&streamError];
    if (streamError != nil) {
        return nil;
    }

    [condition lock];
    while (!finished) {
        [condition wait];
    }
    [condition unlock];
    return result;
}

// Error sheets show why a tool failed without dumping full transcripts.
- (NSError *)toolFailure:(DUStorageErrorCode)code
                 message:(NSString *)message
                  result:(DUProcessResult *)result
{
    NSString *detail =
        [DUParsing trimmedString:result.standardError]
        ?: @"";
    if (detail.length == 0) {
        detail = [DUParsing trimmedString:result.standardOutput] ?: @"";
    }
    NSUInteger tailStart = detail.length > 400 ? detail.length - 400 : 0;
    NSString *tail = [detail substringFromIndex:tailStart];

    NSError *error = [NSError errorWithDomain:DUStorageErrorDomain
                                         code:code
                                     userInfo:@{
        NSLocalizedDescriptionKey : message,
        DUFreeBSDBackendDetailKey : tail,
    }];
    return error;
}

- (BOOL)runSucceeded:(DUProcessResult *)result
{
    return result != nil && result.exitedNormally &&
        [result exitedWithStatus:0] && !result.timedOut;
}

// dd progress lines ("123456789 bytes transferred ..." / GNU-style copies)
// carry the authoritative byte count; \r-separated updates arrive inside a
// single buffered line and are split here.
- (unsigned long long)byteCountFromProgressLine:(NSString *)line
{
    unsigned long long highest = 0;
    for (NSString *chunk in [line componentsSeparatedByString:@"\r"]) {
        NSString *text = [DUParsing trimmedString:
                                   [chunk stringByReplacingOccurrencesOfString:@"\r"
                                                                    withString:@""]];
        if (text.length == 0) {
            continue;
        }
        // The byte count leads the dd line ("<n> bytes transferred ..."),
        // so only a " bytes" marker behind a leading number carries one;
        // parse the digits before the marker, never behind it.
        NSRange suffix = [text rangeOfString:@" bytes"];
        if (suffix.location == NSNotFound || suffix.location == 0) {
            continue;
        }
        unsigned long long bytes =
            [DUParsing unsignedLongLongFromString:
                           [text substringToIndex:suffix.location]];
        if (bytes > highest) {
            highest = bytes;
        }
    }
    // The latest count, not the first: a line can carry several ticks, and
    // returning the earliest one pinned the progress bar near 0% for the
    // whole copy.
    return highest;
}

#pragma mark - Filesystem classification

// Checker binary for a filesystem identifier; nil when this backend cannot
// inspect it. Verify passes read-only flags, repair gets -y.
- (NSString *)checkerNameForFilesystem:(NSString *)fstype
{
    NSString *normalized = fstype.lowercaseString;
    if ([normalized isEqualToString:@"ufs"]) {
        return @"fsck_ffs";
    }
    if ([normalized isEqualToString:@"msdosfs"] ||
        [normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"]) {
        return @"fsck_msdosfs";
    }
    return nil;
}

- (NSArray<NSString *> *)readonlyArgumentsForChecker:(NSString *)checker
{
    return [checker isEqualToString:@"fsck_ffs"] ? @[ @"-n", @"-f" ]
                                                 : @[ @"-n" ];
}

// mount(8) -t spellings differ from our canonical identifiers.
- (NSString *)mountTypeForFilesystem:(NSString *)fstype
{
    NSDictionary<NSString *, NSString *> *table = @{
        @"ufs" : @"ufs",
        @"msdosfs" : @"msdosfs",
        @"fat32" : @"msdosfs",
        @"vfat" : @"msdosfs",
        @"cd9660" : @"cd9660",
        @"iso9660" : @"cd9660",
        @"ntfs" : @"ntfs",
        @"ext2" : @"ext2fs",
        @"ext3" : @"ext2fs",
        @"ext4" : @"ext2fs",
        @"exfat" : @"exfat",
    };
    NSString *mapped = table[fstype.lowercaseString];
    return mapped ?: fstype;
}

- (NSString *)formatterNameForFormatIdentifier:(NSString *)identifier
                                 labelCapacity:(NSUInteger *)outLabelLimit
{
    NSString *normalized = identifier.lowercaseString;
    if ([normalized isEqualToString:@"ufs"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxUFSLabelLength;
        }
        return @"newfs";
    }
    if ([normalized isEqualToString:@"fat32"] ||
        [normalized isEqualToString:@"fat16"] ||
        [normalized isEqualToString:@"vfat"] ||
        [normalized isEqualToString:@"fat"] ||
        [normalized isEqualToString:@"msdosfs"]) {
        if (outLabelLimit != NULL) {
            *outLabelLimit = kMaxFATLabelLength;
        }
        return @"newfs_msdos";
    }
    return nil;
}

// gpart add -t payload for a requested filesystem identifier under the
// given normalized scheme ("gpt", "mbr", "bsd"). gpart(8) translates its
// symbolic names per scheme: the FAT family is "fat32"/"fat16" on MBR but
// "ms-basic-data" on GPT, and the freebsd-* names only exist for GPT and
// BSD labels - handing them to MBR makes gpart reject the partition after
// the table was already created. "!fat32" is valid in neither scheme.
// nil when no honest mapping exists (callers reject rather than guess).
- (NSString *)gpartTypeForFilesystem:(NSString *)fstype
                               scheme:(NSString *)scheme
{
    NSString *type = fstype.lowercaseString;
    if (type.length == 0) {
        return nil;
    }
    NSString *normalizedScheme =
        [DUPartitionTableParser normalizeSchemeToken:scheme] ?: @"";
    BOOL isGPT = [normalizedScheme isEqualToString:@"gpt"];
    BOOL isMBR = [normalizedScheme isEqualToString:@"mbr"];
    BOOL isBSD = [normalizedScheme isEqualToString:@"bsd"];

    if ([type isEqualToString:@"ufs"] ||
        [type isEqualToString:@"freebsd-ufs"]) {
        // UFS data partitions live on GPT or inside a BSD-labelled slice;
        // bare MBR has no standalone UFS partition type.
        return isGPT || isBSD ? @"freebsd-ufs" : nil;
    }
    if ([type isEqualToString:@"swap"]) {
        return isGPT || isBSD ? @"freebsd-swap" : nil;
    }
    if ([type isEqualToString:@"fat32"] ||
        [type isEqualToString:@"fat16"] ||
        [type isEqualToString:@"vfat"] ||
        [type isEqualToString:@"fat"] ||
        [type isEqualToString:@"msdosfs"]) {
        if (isMBR) {
            return [type isEqualToString:@"fat16"] ? @"fat16" : @"fat32";
        }
        return isGPT ? @"ms-basic-data" : nil;
    }
    if ([type isEqualToString:@"efi"]) {
        return isGPT || isMBR ? @"efi" : nil;
    }
    if ([type isEqualToString:@"ext2"] ||
        [type isEqualToString:@"ext3"] ||
        [type isEqualToString:@"ext4"] ||
        [type isEqualToString:@"linux"] ||
        [type isEqualToString:@"linux-data"]) {
        return isGPT || isMBR ? @"linux-data" : nil;
    }
    return nil;
}

// Filesystem relevant to verify/repair/erase for any object kind.
- (NSString *)filesystemTypeOfObject:(DUStorageObject *)object
{
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        return ((DUStorageVolume *)object).filesystemType;
    }
    if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        return partition.volume.filesystemType ?: partition.filesystemType;
    }
    if ([object isKindOfClass:[DUOpticalMedia class]]) {
        return ((DUOpticalMedia *)object).filesystemType;
    }
    return nil;
}

- (unsigned long long)sizeOfObject:(DUStorageObject *)object
{
    if ([object isKindOfClass:[DUStorageDevice class]]) {
        return ((DUStorageDevice *)object).capacityBytes;
    }
    if ([object isKindOfClass:[DUPartition class]]) {
        DUPartition *partition = (DUPartition *)object;
        return partition.sizeBytes ?: partition.volume.capacityBytes;
    }
    if ([object isKindOfClass:[DUStorageVolume class]]) {
        return ((DUStorageVolume *)object).capacityBytes;
    }
    if ([object isKindOfClass:[DUOpticalMedia class]]) {
        return ((DUOpticalMedia *)object).capacityBytes;
    }
    return 0;
}

#pragma mark - Mount-state guards

// The node of this object plus every descendant node, used to refuse
// destructive work while anything above is mounted.
- (NSArray<NSString *> *)nodesOfSubtree:(DUStorageObject *)object
{
    NSMutableArray<NSString *> *nodes = [NSMutableArray array];
    if (object.backendPath.length > 0) {
        [nodes addObject:object.backendPath];
    }
    for (DUStorageObject *child in object.children) {
        [nodes addObjectsFromArray:[self nodesOfSubtree:child]];
    }
    return nodes;
}

- (NSArray<NSString *> *)mountedNodesAmong:(NSArray<NSString *> *)nodes
{
    NSDictionary<NSString *, NSDictionary *> *table =
        [DUFreeBSDGEOMAdapter currentMountTable];
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *node in nodes) {
        if (table[node] != nil && ![found containsObject:node]) {
            [found addObject:node];
        }
    }
    // Whole-disk work must also catch mounted slices like /dev/ada0p2 whose
    // names extend the disk node; partition nodes are matched exactly above.
    // The node name has to be checked with the partition separator, or a
    // mounted /dev/da10p1 reads as a child of /dev/da1.
    for (NSString *node in nodes) {
        NSString *base = node.lastPathComponent;
        if (!IsWholeDiskNodeName(base)) {
            continue;
        }
        for (NSString *mountedNode in table) {
            NSString *mounted = mountedNode.lastPathComponent;
            if (![mounted isEqualToString:base] &&
                IsNodeOnDisk(mounted, base) &&
                ![found containsObject:mountedNode]) {
                [found addObject:mountedNode];
            }
        }
    }
    return found;
}

- (NSString *)mountedNodeAmong:(NSArray<NSString *> *)nodes
{
    return [self mountedNodesAmong:nodes].firstObject;
}

// newfs and gpart refuse a device that is in use, so Erase and Partition
// detach every mounted filesystem of the target first. Blocking; worker
// threads only. Nested mounts go first so a parent is never busy because of
// its own child.
- (NSError *)unmountMountsAmong:(NSArray<NSString *> *)nodes
{
    NSArray<NSString *> *mounted = [self mountedNodesAmong:nodes];
    if (mounted.count == 0) {
        return nil;
    }
    NSString *umountPath = [DUFreeBSDToolCache pathForTool:@"umount"];
    if (umountPath == nil) {
        return DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The umount tool is not "
                                             @"installed.", nil));
    }
    NSDictionary<NSString *, NSDictionary *> *table =
        [DUFreeBSDGEOMAdapter currentMountTable];
    NSArray<NSString *> *ordered = [mounted sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger la = [table[a][@"mountPoint"] length];
            NSUInteger lb = [table[b][@"mountPoint"] length];
            if (la == lb) {
                return NSOrderedSame;
            }
            return la > lb ? NSOrderedAscending : NSOrderedDescending;
        }];
    for (NSString *node in ordered) {
        NSString *mountPoint = table[node][@"mountPoint"];
        if (mountPoint.length == 0) {
            continue;
        }
        // umount detaches a filesystem for the whole session; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:umountPath
                         args:@[ mountPoint ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:result]) {
            return [self toolFailure:DUErrorUnmountError
                             message:[NSString stringWithFormat:
                                          NSLocalizedString(
                                              @"%@ could not be unmounted.",
                                              nil),
                                      node]
                              result:result];
        }
    }
    return nil;
}

#pragma mark - Whole-disk verify

/* Verifies every verifiable partition of a disk sequentially. The overall
 * fraction is (done + partitionFraction) / total so the bar sweeps once
 * across all children; partitions without a checker are reported and
 * skipped, and the first fsck failure fails the whole operation after all
 * children ran. */
- (void)verifyPartitionsOfDevice:(DUStorageDevice *)device
                        progress:(void (^)(double progress,
                                           NSString *message))progress
                      completion:(void (^)(NSError *))completion
{
    NSMutableArray<DUPartition *> *verifiable = [NSMutableArray new];
    NSMutableArray<DUPartition *> *skipped = [NSMutableArray new];
    /* The whole SUBTREE, not just the disk's direct children: a BSD label
     * nests its partitions one level below their slice (ada0s1a hangs off
     * ada0s1), so walking only the children found nothing to check on those
     * disks and then reported "All partitions verified clean." */
    NSMutableArray<DUPartition *> *partitions = [NSMutableArray array];
    NSMutableArray<DUStorageObject *> *pending =
        [NSMutableArray arrayWithArray:device.children];
    while (pending.count > 0) {
        DUStorageObject *child = pending.lastObject;
        [pending removeLastObject];
        if ([child isKindOfClass:[DUPartition class]]) {
            [partitions addObject:(DUPartition *)child];
        }
        [pending addObjectsFromArray:child.children];
    }
    for (DUPartition *partition in partitions) {
        NSString *checker =
            [self checkerNameForFilesystem:
                      partition.filesystemType ?: @""];
        if (partition.backendPath.length == 0 || checker == nil) {
            [skipped addObject:partition];
        } else {
            [verifiable addObject:partition];
        }
    }

    /* Nothing was actually checked. Saying "verified clean" here is a lie
     * that matters: the user is told their disk is sound when no checker
     * ever ran. */
    if (verifiable.count == 0) {
        /* A whole-disk erase leaves a filesystem on the device node itself
         * and no partition table at all, so "no partitions" does not mean
         * "nothing to check" - it is the normal end state of Erase. Verify
         * the device's own filesystem in that case. */
        if (partitions.count == 0) {
            [self verifyFilesystemAtNode:device.backendPath
                                    named:device.displayName
                                  progress:progress
                                completion:completion];
            return;
        }
        completion(DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(
                @"None of this disk's filesystems can be verified with the "
                @"tools installed.",
                nil)));
        return;
    }

    progress(0.0, [NSString stringWithFormat:
        NSLocalizedString(@"Verifying %lu partitions on %@...", nil),
        (unsigned long)verifiable.count,
        device.displayName ?: @""]);

    NSUInteger total = verifiable.count + skipped.count;
    __block NSUInteger done = 0;
    __block DUPartition *failedPartition = nil;
    __block NSString *failureDetail = nil;

    __block void (^next)(void) = ^void(void) {
        if (done >= total) {
            next = nil;  /* break the self-reference */
            if (failedPartition == nil) {
                progress(1.0, NSLocalizedString(
                    @"All partitions verified clean.", nil));
                completion(nil);
            } else {
                progress(1.0, NSLocalizedString(
                    @"Verification found errors.", nil));
                completion([NSError errorWithDomain: DUStorageErrorDomain
                                               code: DUErrorVerificationFailed
                                           userInfo: @{
                    NSLocalizedDescriptionKey :
                        [NSString stringWithFormat:
                            NSLocalizedString(
                                @"Partition %@ could not be verified "
                                @"without errors.", nil),
                            failedPartition.displayName ?: @""],
                    DUFreeBSDBackendDetailKey : failureDetail ?: @"",
                }]);
            }
            return;
        }

        NSUInteger index = done;
        double base = (double)index / (double)total;
        double span = 1.0 / (double)total;

        if (index < skipped.count) {
            DUPartition *partition = skipped[index];
            done++;
            progress(done / (double)total, [NSString stringWithFormat:
                NSLocalizedString(@"[%lu/%lu] %@ has no verifiable "
                                  @"filesystem - skipped.", nil),
                (unsigned long)(index + 1), (unsigned long)total,
                partition.displayName ?: @""]);
            next();
            return;
        }

        DUPartition *partition = verifiable[index - skipped.count];
        NSString *prefix = [NSString stringWithFormat:@"[%lu/%lu] %@:",
            (unsigned long)(index + 1), (unsigned long)total,
            partition.displayName ?: @""];
        NSString *checker =
            [self checkerNameForFilesystem:partition.filesystemType ?: @""];
        NSArray *readonlyArgs =
            [self readonlyArgumentsForChecker:checker];
        NSString *checkerPath =
            [DUFreeBSDToolCache pathForTool:checker];

        progress(base, [NSString stringWithFormat:
            NSLocalizedString(@"%@ checking %@...", nil),
            prefix, partition.filesystemType ?: @""]);

        NSMutableArray *arguments =
            [NSMutableArray arrayWithArray:readonlyArgs];
        [arguments addObject:partition.backendPath];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) return;
            lineCount++;
            if (lineCount <= 40 && progress != NULL) {
                progress(base + span * 0.5,
                         [NSString stringWithFormat:@"%@ %@", prefix, text]);
            }
        }];
        done++;
        if (![self runSucceeded:result]) {
            failedPartition = failedPartition ?: partition;
            failureDetail = result.standardError ?: @"";
            progress(done / (double)total, [NSString stringWithFormat:
                NSLocalizedString(@"%@ errors found.", nil), prefix]);
        } else {
            progress(done / (double)total, [NSString stringWithFormat:
                NSLocalizedString(@"%@ clean.", nil), prefix]);
        }
        next();
    };
    next();
}

#pragma mark - Verify

/* Checks a filesystem that lives directly on a node, with no partition
 * involved. This is the state a whole-disk erase leaves behind, and it is
 * also what a freshly created image file is before it is partitioned, so
 * verifying the device itself has to be a first-class path rather than a
 * "no partitions" refusal. */
- (void)verifyFilesystemAtNode:(NSString *)node
                         named:(NSString *)name
                      progress:(void (^)(double progress,
                                         NSString *message))progress
                    completion:(void (^)(NSError *error))completion
{
    if (node.length == 0) {
        if (completion != NULL) {
            completion(DUErrorMake(DUErrorInvalidArgument,
                                   NSLocalizedString(@"The item has no device "
                                                     @"node.", nil)));
        }
        return;
    }
    NSString *fstype = [self filesystemTypeAtNode:node];
    NSString *checker = fstype != nil
        ? [self checkerNameForFilesystem:fstype] : nil;
    NSString *checkerPath = checker == nil
        ? nil : [DUFreeBSDToolCache pathForTool:checker];
    if (checkerPath == nil) {
        if (completion != NULL) {
            completion(DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"No filesystem checker for this item is "
                                  @"installed.", nil)));
        }
        return;
    }

    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, [NSString stringWithFormat:
                               NSLocalizedString(@"Checking filesystem on %@...",
                                                 nil),
                               name ?: node]);
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:
                               [self readonlyArgumentsForChecker:checker]];
        [arguments addObject:node];
        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) {
                return;
            }
            lineCount++;
            if (progress != NULL) {
                progress((1.0 - 1.0 / (double)(lineCount + 1)) * 0.95, text);
            }
        }];
        if (![self runSucceeded:result]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorVerificationFailed
                                     message:NSLocalizedString(
                                                  @"The filesystem was found "
                                                  @"to be damaged.", nil)
                                      result:result]);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0, NSLocalizedString(@"Volume verified.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

// The filesystem on a bare node, or nil when it cannot be identified. Probed
// rather than remembered: after an erase the model's filesystemType is gone.
- (NSString *)filesystemTypeAtNode:(NSString *)node
{
    for (NSString *candidate in @[ @"ufs", @"msdosfs" ]) {
        NSString *checker = [self checkerNameForFilesystem:candidate];
        NSString *checkerPath =
            [DUFreeBSDToolCache pathForTool:checker ?: @""];
        if (checkerPath == nil) {
            continue;
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:
                               [self readonlyArgumentsForChecker:checker]];
        [arguments addObject:node];
        DUProcessResult *result =
            [DUProcessRunner runExecutable:checkerPath
                                 arguments:arguments
                                     error:NULL];
        if (result != nil && result.exitedNormally &&
            [result exitedWithStatus:0]) {
            return candidate;
        }
    }
    return nil;
}

- (void)verifyObject:(DUStorageObject *)object
              progress:(void (^)(double progress, NSString *message))progress
            completion:(void (^)(NSError *error))completion
{
    /* A whole disk has no filesystem of its own; verifying it fans out
     * over its partitions with the overall bar advancing per partition. */
    if ([object isKindOfClass: [DUStorageDevice class]]) {
        [self verifyPartitionsOfDevice: (DUStorageDevice *)object
                              progress: progress
                            completion: completion];
        return;
    }

    NSError *gate = [self gateForOperation:kDUOperationVerify
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }
    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSArray<NSString *> *readonlyArgs = nil;
    NSString *checker = gate == nil
        ? [self checkerNameForFilesystem:fstype]
        : nil;
    readonlyArgs =
        checker == nil ? nil : [self readonlyArgumentsForChecker:checker];
    NSString *checkerPath = checker == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem checker for %@ is "
                                   @"installed.", nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Checking filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:readonlyArgs];
        [arguments addObject:node];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) {
                return;
            }
            lineCount++;
            if (progress != NULL) {
                // fsck gives no machine-readable progress; advance a capped
                // fraction per output line so the bar keeps moving honestly.
                double fraction = 1.0 - 1.0 / (double)(lineCount + 1);
                progress(fraction * 0.95, text);
            }
        }];

        if (![self runSucceeded:result]) {
            NSError *error = [self toolFailure:DUErrorVerificationFailed
                                       message:NSLocalizedString(
                                                    @"The filesystem was "
                                                    @"found to be damaged.",
                                                    nil)
                                        result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Volume verified.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Repair

- (void)repairObject:(DUStorageObject *)object
              progress:(void (^)(double progress, NSString *message))progress
            completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationRepair
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    // fsck -y on a live filesystem corrupts it; refuse before spawning.
    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:object]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before repair.", nil),
                            busyNode]);
    }

    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSString *checker = gate == nil
        ? [self checkerNameForFilesystem:fstype]
        : nil;
    NSString *checkerPath = checker == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:checker];
    if (gate == nil && checkerPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"No filesystem repair tool for %@ is "
                                   @"installed.", nil),
             fstype]);
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Repairing filesystem...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithObject:@"-y"];
        [arguments addObject:node];

        __block NSUInteger lineCount = 0;
        DUProcessResult *result = [self blockingStreamedRun:checkerPath
                                                  arguments:arguments
                                                lineHandler:^(NSString *line) {
            NSString *text = [DUParsing trimmedString:line];
            if (text.length == 0) {
                return;
            }
            lineCount++;
            if (progress != NULL) {
                double fraction = 1.0 - 1.0 / (double)(lineCount + 1);
                progress(fraction * 0.95, text);
            }
        }];

        if (![self runSucceeded:result]) {
            NSError *error = [self toolFailure:DUErrorRepairFailed
                                       message:NSLocalizedString(
                                                    @"The filesystem could "
                                                    @"not be repaired.", nil)
                                        result:result];
            if (completion != NULL) {
                completion(error);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Volume repaired.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

- (void)repairHomePermissionsWithProgress:(void (^)(double, NSString *))progress
                                completion:(void (^)(NSError *))completion
{
    [DURepairPermissionsTool repairHomePermissionsWithProgress:progress
                                                     completion:completion];
}

#pragma mark - Erase

// Labels feed tool argv directly, so option-leading characters must go and
// whitespace would split nothing but still confuse tools that echo labels.
- (NSString *)sanitizedLabel:(NSString *)rawLabel limit:(NSUInteger)limit
{
    NSMutableString *label =
        [[DUParsing trimmedString:rawLabel] mutableCopy];
    while (label.length > 0 && [label characterAtIndex:0] == '-') {
        [label deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    [label replaceOccurrencesOfString:@" "
                           withString:@"_"
                              options:0
                                range:NSMakeRange(0, label.length)];
    if (label.length > limit) {
        label = [NSMutableString stringWithString:
                            [label substringToIndex:limit]];
    }
    return label;
}

// newfs and newfs_msdos share the -L label spelling. Blocking; they write the
// raw device, so they run elevated.
- (DUProcessResult *)runFormatter:(NSString *)formatterPath
                             node:(NSString *)node
                            label:(NSString *)label
{
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    if (label.length > 0) {
        [arguments addObjectsFromArray:@[ @"-L", label ]];
    }
    [arguments addObject:node];
    return [[DUAuthorizationManager sharedManager]
        runPrivileged:formatterPath
                 args:arguments
              timeout:300.0
                error:NULL];
}

- (void)eraseObject:(DUStorageObject *)object
             options:(NSDictionary *)options
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion
{
    NSError *gate = [self gateForOperation:kDUOperationErase
                                 onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }
    NSString *formatIdentifier =
        [DUParsing trimmedString:options[kDUFormatIdentifierKey]];
    if (gate == nil && formatIdentifier.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No filesystem was chosen for "
                                             @"the erased volume.", nil));
    }
    NSUInteger labelLimit = 0;
    NSString *formatter = gate == nil
        ? [self formatterNameForFormatIdentifier:formatIdentifier
                                   labelCapacity:&labelLimit]
        : nil;
    if (gate == nil && formatter == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"Formatting as %@ is not supported.",
                                   nil),
             formatIdentifier]);
    }
    NSString *formatterPath = formatter == nil
        ? nil
        : [DUFreeBSDToolCache pathForTool:formatter];
    if (gate == nil && formatterPath == nil) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"The %@ formatting tool is not "
                                   @"installed.", nil),
             formatter]);
    }

    NSString *securityMethod =
        [DUParsing trimmedString:options[kDUEraseSecurityMethodKey]];
    BOOL wipeWithZeros =
        [securityMethod isEqualToString:kDUEraseMethodZerosKey];
    NSString *ddPath = nil;
    if (gate == nil && wipeWithZeros) {
        ddPath = [DUFreeBSDToolCache pathForTool:@"dd"];
        if (ddPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Secure zeroing requires dd, which is "
                                  @"not installed.", nil));
        }
    }

    BOOL wholeDisk = gate == nil && object.type == DUStorageObjectTypeDevice;
    NSString *gpartPath = nil;
    if (gate == nil && wholeDisk) {
        gpartPath = [DUFreeBSDToolCache pathForTool:@"gpart"];
        if (gpartPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Erasing a whole disk requires gpart, "
                                  @"which is not installed.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;
    NSString *volumeName =
        [DUParsing trimmedString:options[@"name"]] ?: @"";
    NSString *label = [self sanitizedLabel:volumeName limit:labelLimit];

    NSArray<NSString *> *subtreeNodes = [self nodesOfSubtree:object];

    [self spawnWork:^{
        double fraction = 0.0;

        NSError *unmountError = [self unmountMountsAmong:subtreeNodes];
        if (unmountError != nil) {
            if (completion != NULL) {
                completion(unmountError);
            }
            return;
        }

        if (wipeWithZeros) {
            if (progress != NULL) {
                progress(0.02,
                         NSLocalizedString(@"Writing zeroes over the "
                                           @"device...", nil));
            }
            unsigned long long totalBytes = [self sizeOfObject:object];
            NSMutableArray<NSString *> *ddArguments = [NSMutableArray array];
            [ddArguments addObjectsFromArray:@[
                @"if=/dev/zero",
                [NSString stringWithFormat:@"of=%@", node],
                @"bs=1M",
                @"status=progress",
            ]];
            /* An explicit count is required, not an optimisation. Left to run
             * until the device is full, dd's final block write is short, the
             * tool exits nonzero and the app reported "Zeroing the device
             * failed" on a volume it had in fact just wiped. Counting the
             * blocks makes the copy end cleanly and the verdict honest. */
            if (totalBytes > 0) {
                [ddArguments addObject:
                    [NSString stringWithFormat:@"count=%llu",
                                               (totalBytes + (1024 * 1024) - 1) /
                                                   (1024 * 1024)]];
            }
            DUProcessResult *wipe = [self
                blockingStreamedRun:ddPath
                          arguments:ddArguments
                        lineHandler:^(NSString *line) {
                    unsigned long long written =
                        [self byteCountFromProgressLine:line];
                    if (written == 0 || totalBytes == 0) {
                        return;
                    }
                    double ratio =
                        (double)written / (double)totalBytes;
                    if (ratio > 1.0) {
                        ratio = 1.0;
                    }
                    if (progress != NULL) {
                        progress(0.02 + ratio * 0.73,
                                 NSLocalizedString(@"Writing zeroes...",
                                                   nil));
                    }
                }];
            if (![self runSucceeded:wipe]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorEraseFailed
                                         message:NSLocalizedString(
                                                      @"Zeroing the device "
                                                      @"failed.", nil)
                                          result:wipe]);
                }
                return;
            }
            fraction = 0.75;
        }

        if (wholeDisk) {
            fraction = fraction > 0 ? fraction : 0.2;
            if (progress != NULL) {
                progress(fraction,
                         NSLocalizedString(@"Removing the partition "
                                           @"table...", nil));
            }
            // gpart destroy rewrites the table; needs root. Only run it when
            // there IS a table: on an already-blank disk gpart exits nonzero
            // with a wording that is not the same on every build, and
            // matching one spelling read a normal "nothing to remove" as a
            // failure to remove the table - which is what a second Erase of
            // the same disk is.
            DUProcessResult *destroy = nil;
            NSString *nodeName = node.lastPathComponent;
            if ([self partitionTableExistsOn:nodeName gpartPath:gpartPath]) {
                destroy =
                    [[DUAuthorizationManager sharedManager]
                        runPrivileged:gpartPath
                                 args:@[ @"destroy", @"-F", nodeName ]
                              timeout:300.0
                                error:NULL];
            }
            if (destroy != nil && ![self runSucceeded:destroy]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorEraseFailed
                                         message:NSLocalizedString(
                                                      @"Removing the old "
                                                      @"partition table "
                                                      @"failed.", nil)
                                          result:destroy]);
                }
                return;
            }
            fraction += 0.05;
        }

        if (progress != NULL) {
            progress(fraction + 0.1,
                     NSLocalizedString(@"Creating filesystem...", nil));
        }
        DUProcessResult *created = [self runFormatter:formatterPath
                                                 node:node
                                                label:label];
        if (![self runSucceeded:created]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorEraseFailed
                                     message:NSLocalizedString(
                                                  @"Creating the filesystem "
                                                  @"failed.", nil)
                                      result:created]);
            }
            return;
        }

        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Erase completed.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Partitioning

- (void)partitionDevice:(DUStorageObject *)device
                withPlan:(DUPartitionPlan *)plan
               progress:(void (^)(double progress, NSString *message))progress
             completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationPartition onObject:device];
    if (gate == nil && plan == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No partition plan was given.",
                                             nil));
    }
    if (gate == nil && device.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The device has no device "
                                             @"node.", nil));
    }

    NSString *scheme = gate == nil
        ? [DUPartitionTableParser normalizeSchemeToken:plan.scheme]
        : nil;
    if (gate == nil &&
        !([scheme isEqualToString:@"gpt"] ||
          [scheme isEqualToString:@"mbr"] ||
          [scheme isEqualToString:@"bsd"])) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"Partition scheme %@ is not supported.",
                                   nil),
             plan.scheme ?: @""]);
    }

    // Resolve every entry type up front so an unmappable filesystem fails
    // synchronously instead of after the table was already destroyed.
    NSArray<DUPartition *> *entries = gate == nil ? plan.entries : nil;
    NSMutableArray<NSString *> *types =
        [NSMutableArray arrayWithCapacity:entries.count];
    if (gate == nil) {
        for (DUPartition *entry in entries) {
            NSString *requested =
                [DUParsing trimmedString:entry.filesystemType]
                ?: @"";
            if (requested.length == 0) {
                requested =
                    [DUFreeBSDGEOMAdapter filesystemTokenForPartitionType:
                                              entry.partitionType] ?: @"";
            }
            NSString *type =
                [self gpartTypeForFilesystem:requested scheme:scheme];
            if (type == nil) {
                gate = DUErrorMake(
                    DUErrorInvalidArgument,
                    [NSString stringWithFormat:
                         NSLocalizedString(@"No partition type mapping "
                                           @"exists for %@.", nil),
                     requested]);
                break;
            }
            [types addObject:type];
        }
    }

    NSString *gpartPath = nil;
    if (gate == nil) {
        gpartPath = [DUFreeBSDToolCache pathForTool:@"gpart"];
        if (gpartPath == nil) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"Partitioning requires gpart, which is "
                                  @"not installed.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    /* Sector size comes from the DISK provider, not from the part class: a
     * disk with no table yet has no part providers at all, so the old lookup
     * silently fell back to 512 - which makes every partition 8x too large on
     * a 4Kn drive (gpart add -s counts media sectors, not bytes) and the first
     * partition then swallows the disk. */
    NSString *nodeName = device.backendPath.lastPathComponent;
    unsigned long long sectorSize = 0;
    for (NSDictionary *provider in [DUFreeBSDGEOMAdapter listClass:@"disk"
                                                              name:nodeName
                                                              error:NULL]) {
        sectorSize = [DUParsing unsignedLongLongFromString:
                                 [DUParsing trimmedString:
                                            provider[@"sectorsize"]]];
        if (sectorSize > 0) {
            break;
        }
    }
    if (sectorSize == 0) {
        for (NSDictionary *provider in
                 [DUFreeBSDGEOMAdapter listClass:@"part"
                                           name:nodeName
                                           error:NULL]) {
            sectorSize = [DUParsing unsignedLongLongFromString:
                                     [DUParsing trimmedString:
                                                provider[@"sectorsize"]]];
            if (sectorSize > 0) {
                break;
            }
        }
    }
    if (sectorSize == 0) {
        // Refuse rather than guess a sector size: the wrong one produces a
        // table whose partitions do not match what the user asked for, on a
        // disk whose old table has already been destroyed.
        if (completion != NULL) {
            completion(DUErrorMake(
                DUErrorBackendUnavailable,
                NSLocalizedString(@"The sector size of this disk could not be "
                                  @"read, so the partition sizes cannot be "
                                  @"computed safely.", nil)));
        }
        return;
    }

    NSArray<NSString *> *subtreeNodes = [self nodesOfSubtree:device];
    unsigned long long diskBytes = [self sizeOfObject:device];

    [self spawnWork:^{
        // Rewriting the table under mounted filesystems would lose their
        // contents and gpart refuses a busy provider, so detach them first.
        NSError *unmountError = [self unmountMountsAmong:subtreeNodes];
        if (unmountError != nil) {
            if (completion != NULL) {
                completion(unmountError);
            }
            return;
        }
        if (progress != NULL) {
            progress(0.02,
                     NSLocalizedString(@"Creating partition table...",
                                       nil));
        }
        /* Applying a plan rewrites the whole table, so an existing one has to
         * go first: gpart(8) leaves the entries of a table it recognises
         * alone, which silently merges the old partitions into the new
         * scheme and then makes every gpart add -i land on an occupied slot.
         *
         * Whether there IS a table is asked first rather than inferred from
         * the destroy's exit code: gpart(8) reports an unlabelled disk
         * differently across builds ("No such geom: da1" on some, "arg0
         * 'da1': Invalid argument" on this one), and both are a normal
         * "nothing to remove" rather than a failure. */
        BOOL tableExists = [self partitionTableExistsOn:nodeName
                                               gpartPath:gpartPath];
        if (tableExists) {
            DUProcessResult *destroyed =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:gpartPath
                             args:@[ @"destroy", @"-F", nodeName ]
                          timeout:300.0
                            error:NULL];
            if (![self runSucceeded:destroyed]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorPartitionError
                                         message:NSLocalizedString(
                                                      @"Removing the old "
                                                      @"partition table "
                                                      @"failed.", nil)
                                          result:destroyed]);
                }
                return;
            }
        }

        // gpart create rewrites the table; needs root.
        DUProcessResult *created =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:gpartPath
                         args:@[ @"create", @"-s", scheme, nodeName ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:created]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorPartitionError
                                     message:NSLocalizedString(
                                                  @"Creating the partition "
                                                  @"table failed.", nil)
                                      result:created]);
            }
            return;
        }

        NSUInteger count = entries.count;
        NSUInteger labelLimit = 0;
        NSMutableArray<NSString *> *newNodes =
            [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            DUPartition *entry = entries[i];
            NSMutableArray<NSString *> *arguments =
                [NSMutableArray arrayWithObject:@"add"];
            [arguments addObjectsFromArray:@[ @"-t", types[i] ]];

            // 1 MiB alignment keeps partitions on flash erase blocks and
            // 4Kn sector boundaries.
            [arguments addObjectsFromArray:@[ @"-a", @"1m" ]];

            /* The last entry that reaches the end of the disk gets no -s:
             * gpart then takes exactly what is left of the usable area, which
             * excludes the backup table and the alignment slack. An explicit
             * size computed from the plan runs past that and gpart rejects
             * the add after the table was already rewritten. */
            BOOL reachesDiskEnd = i + 1 == count && diskBytes > 0 &&
                entry.offsetBytes + entry.sizeBytes + (1024ull * 1024ull) >
                    diskBytes;
            if (entry.sizeBytes > 0 && !reachesDiskEnd) {
                // Round up so rounding can never swallow part of the last
                // partition into unallocated space.
                unsigned long long sectors =
                    (entry.sizeBytes + sectorSize - 1) / sectorSize;
                [arguments addObjectsFromArray:
                                @[ @"-s",
                                   [NSString stringWithFormat:@"%llu",
                                                              sectors] ]];
            }
            /* No -i: gpart numbers the table from 1 and the layout numbers its
             * entries from 0, so passing the layout index made every add after
             * the first collide with a slot gpart had just used. Entries arrive
             * in ascending offset order and gpart appends in call order, so
             * letting gpart assign the index reproduces the layout exactly. */
            if ([scheme isEqualToString:@"gpt"] &&
                entry.name.length > 0) {
                NSString *label =
                    [self sanitizedLabel:entry.name limit:kMaxUFSLabelLength];
                if (label.length > 0) {
                    [arguments addObjectsFromArray:@[ @"-l", label ]];
                }
            }
            [arguments addObject:nodeName];

            if (progress != NULL) {
                progress(0.1 + 0.85 * (double)(i + 1) / (double)count,
                         [NSString stringWithFormat:
                              NSLocalizedString(@"Adding partition %lu of %lu...",
                                                nil),
                              (unsigned long)(i + 1), (unsigned long)count]);
            }
            // gpart add rewrites the table; needs root.
            DUProcessResult *added =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:gpartPath
                             args:arguments
                          timeout:300.0
                            error:NULL];
            if (![self runSucceeded:added]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorPartitionError
                                         message:NSLocalizedString(
                                                      @"Adding a partition "
                                                      @"failed.", nil)
                                          result:added]);
                }
                return;
            }
            // gpart names the new provider itself ("da0p1 added"); asking it
            // is the only way to know the node under every scheme.
            NSString *addedLine =
                [DUParsing trimmedString:added.standardOutput] ?: @"";
            NSString *newName = [[addedLine
                componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                firstObject];
            BOOL parsed = newName.length > 0 && [addedLine hasSuffix:@"added"];
            [newNodes addObject:parsed
                     ? [@"/dev" stringByAppendingPathComponent:newName]
                     : @""];
        }

        // gpart only records the type; without newfs every new partition
        // stays blank although the user chose a format and a name for it.
        for (NSUInteger i = 0; i < count; i++) {
            DUPartition *entry = entries[i];
            NSString *formatter = [self
                formatterNameForFormatIdentifier:entry.filesystemType
                                   labelCapacity:&labelLimit];
            if (formatter == nil) {
                continue;
            }
            if ([newNodes[i] length] == 0) {
                if (completion != NULL) {
                    completion(DUErrorMake(
                        DUErrorPartitionError,
                        NSLocalizedString(@"gpart did not report the name "
                                          @"of a new partition, so it cannot "
                                          @"be formatted.", nil)));
                }
                return;
            }
            NSString *formatterPath =
                [DUFreeBSDToolCache pathForTool:formatter];
            if (formatterPath == nil) {
                if (completion != NULL) {
                    completion(DUErrorMake(
                        DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:
                             NSLocalizedString(@"The %@ formatting tool is "
                                               @"not installed.", nil),
                             formatter]));
                }
                return;
            }
            if (progress != NULL) {
                progress(0.95,
                         [NSString stringWithFormat:
                              NSLocalizedString(@"Formatting partition %lu "
                                                @"of %lu...", nil),
                              (unsigned long)(i + 1), (unsigned long)count]);
            }
            DUProcessResult *formatted = [self
                runFormatter:formatterPath
                        node:newNodes[i]
                       label:[self sanitizedLabel:entry.name ?: @""
                                            limit:labelLimit]];
            if (![self runSucceeded:formatted]) {
                if (completion != NULL) {
                    completion([self toolFailure:DUErrorPartitionError
                                         message:NSLocalizedString(
                                                      @"Creating the "
                                                      @"filesystem on a new "
                                                      @"partition failed.",
                                                      nil)
                                          result:formatted]);
                }
                return;
            }
        }

        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Partitions created.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - Mount management

// Where a volume is mounted when the app mounts it: under the user's own
// directory, because the app is not root and cannot create a directory
// directly under /media. Created on demand; the caller reports the failure.
- (NSString *)mountPointForNode:(NSString *)node
{
    NSString *home = NSHomeDirectory();
    if (home.length == 0) {
        home = NSTemporaryDirectory();
    }
    NSString *root = [home stringByAppendingPathComponent:@".disk-utility"
                                                            "/mounts"];
    NSString *directory =
        [root stringByAppendingPathComponent:node.lastPathComponent];
    NSError *directoryError = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError] == NO &&
        directoryError != nil) {
        return nil;
    }
    return directory;
}

- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error, NSString *mountPoint))completion
{
    NSError *gate = nil;
    if (object == nil || object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    } else {
        /* Not gated on -supportsOperation:kDUOperationMount: for the same
         * reason unmount is not gated on its flag. canMount is computed from
         * the mount state at snapshot time, so a freshly created partition
         * that is not in any snapshot yet - or a volume mounted and then
         * unmounted - arrives with canMount = NO and Mount is refused even
         * though mount(8) would succeed. The real preconditions (a tool, a
         * known filesystem, an unmounted node) are checked below. */
    }

    NSString *mountPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"mount"]
        : nil;
    if (gate == nil && mountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The mount tool is not "
                                             @"installed.", nil));
    }

    NSString *node = gate == nil ? object.backendPath : nil;
    if (gate == nil) {
        NSDictionary *existing =
            [DUFreeBSDGEOMAdapter currentMountTable][node];
        if (existing != nil) {
            // Already up: surface the existing state instead of stacking a
            // second mount.
            if (completion != NULL) {
                completion(nil, existing[@"mountPoint"]);
            }
            return;
        }
    }

    NSString *fstype = gate == nil ? [self filesystemTypeOfObject:object] : nil;
    NSString *mountType = gate == nil && fstype.length > 0
        ? [self mountTypeForFilesystem:fstype]
        : nil;
    if (gate == nil && mountType.length == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The filesystem type of this item is "
                              @"unknown, so it cannot be mounted.", nil));
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate, nil);
        }
        return;
    }

    /* The mount point has to live somewhere the unprivileged GUI process can
     * create it. /media is root-owned, so mkdir /media/<node> failed with
     * EACCES and every Mount in the app died with "the mount point could not
     * be created". The user's own data directory always works and keeps the
     * volume reachable between sessions. */
    NSString *directory = [self mountPointForNode:node];
    if (directory == nil) {
        if (completion != NULL) {
            completion(DUErrorMake(
                DUErrorMountError,
                NSLocalizedString(@"A mount point for this volume could not be "
                                  @"created in your home directory.", nil)),
                       nil);
        }
        return;
    }

    [self spawnWork:^{
        // mount(8) attaches a filesystem for the whole session; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:mountPath
                         args:@[ @"-t", mountType, node, directory ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:result]) {
            if (completion != NULL) {
                completion([self toolFailure:DUErrorMountError
                                     message:NSLocalizedString(
                                                  @"Mounting failed.", nil)
                                      result:result],
                           nil);
            }
            return;
        }
        /* Report the mount point the SYSTEM recorded, and only if something
         * really is mounted there: mount(8) can exit 0 while the requested
         * directory stays an ordinary directory, and handing that path back
         * is what made the unmount right afterwards fail with "This item is
         * not mounted." while the browser showed a mounted volume. */
        NSString *recorded =
            [DUFreeBSDGEOMAdapter currentMountTable][node][@"mountPoint"];
        if (recorded.length == 0) {
            [self unmountQuietly:directory];
            if (completion != NULL) {
                completion([self toolFailure:DUErrorMountError
                                     message:NSLocalizedString(
                                                  @"Mounting failed: nothing "
                                                  @"was attached at %@.", nil)
                                      result:result],
                           nil);
            }
            return;
        }
        if (completion != NULL) {
            completion(nil, recorded);
        }
    }];
}

- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *error))completion
{
    NSError *gate = nil;
    if (object == nil || object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    } else {
        /* Deliberately NOT gated on -supportsOperation:kDUOperationUnmount:.
         * Discovery sets canUnmount from the mount state captured when the
         * snapshot was built, so a volume mounted since then arrives with
         * canUnmount = NO and every Unmount was refused as
         * "\"unmount\" cannot be performed on <volume>" - the user could
         * mount a volume and then not be able to unmount it. The real
         * precondition is the live mount table, which is checked below and
         * produces the honest "This item is not mounted." when it applies. */
    }

    NSString *umountPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"umount"]
        : nil;
    if (gate == nil && umountPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"The umount tool is not "
                                             @"installed.", nil));
    }

    NSString *target = nil;
    if (gate == nil) {
        // The live mount table is authoritative, with the snapshot's recorded
        // mount point only as a fallback: it is what tells us where the
        // filesystem is now.
        target =
            [DUFreeBSDGEOMAdapter currentMountTable][object.backendPath][@"mountPoint"];
        if (target.length == 0 &&
            [object isKindOfClass:[DUStorageVolume class]]) {
            target = ((DUStorageVolume *)object).mountPoint;
        }
        if (target.length == 0) {
            gate = DUErrorMake(DUErrorUnmountError,
                               NSLocalizedString(@"This item is not "
                                                 @"mounted.", nil));
        }
    }

    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    [self spawnWork:^{
        // umount detaches a filesystem for the whole session; needs root.
        DUProcessResult *result =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:umountPath
                         args:@[ target ]
                      timeout:300.0
                        error:NULL];
        if (![self runSucceeded:result]) {
            BOOL busy = [DUParsing caseInsensitiveContains:result.standardError
                                                     needle:@"busy"];
            NSString *message = busy
                ? NSLocalizedString(@"The volume is still in use.", nil)
                : NSLocalizedString(@"Unmounting failed.", nil);
            DUStorageErrorCode code =
                busy ? DUErrorDeviceBusy : DUErrorUnmountError;
            if (completion != NULL) {
                completion([self toolFailure:code
                                     message:message
                                      result:result]);
            }
            return;
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationEject onObject:object];
    if (gate == nil && object.backendPath.length == 0) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"The item has no device node.",
                                             nil));
    }

    NSString *cdcontrolPath = [DUFreeBSDToolCache pathForTool:@"cdcontrol"];
    NSString *camcontrolPath = [DUFreeBSDToolCache pathForTool:@"camcontrol"];
    BOOL optical = NO;
    if (gate == nil) {
        if ([object isKindOfClass:[DUStorageDevice class]]) {
            optical = ((DUStorageDevice *)object).optical;
        } else {
            DUStorageObject *ancestor = object.parent;
            while (ancestor != nil) {
                if ([ancestor isKindOfClass:[DUStorageDevice class]]) {
                    optical = ((DUStorageDevice *)ancestor).optical;
                    break;
                }
                ancestor = ancestor.parent;
            }
        }
    }
    if (gate == nil && cdcontrolPath == nil && camcontrolPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Neither cdcontrol nor "
                                             @"camcontrol is installed.",
                                             nil));
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    NSString *node = object.backendPath;

    [self spawnWork:^{
        DUProcessResult *failure = nil;

        // Optical media leaves via cdcontrol first; tray semantics live
        // there, not in CAM. Anything else goes straight to camcontrol.
        // Both commands drive the drive hardware; needs root.
        if (optical && cdcontrolPath != nil) {
            DUProcessResult *result =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:cdcontrolPath
                             args:@[ @"-f", node, @"eject" ]
                          timeout:300.0
                            error:NULL];
            if ([self runSucceeded:result]) {
                if (completion != NULL) {
                    completion(nil);
                }
                return;
            }
            failure = result;
        }

        if (camcontrolPath != nil) {
            DUProcessResult *result =
                [[DUAuthorizationManager sharedManager]
                    runPrivileged:camcontrolPath
                             args:@[ @"eject",
                                     node.lastPathComponent ]
                          timeout:300.0
                            error:NULL];
            if ([self runSucceeded:result]) {
                if (completion != NULL) {
                    completion(nil);
                }
                return;
            }
            failure = failure ?: result;
        }

        if (completion != NULL) {
            completion([self toolFailure:DUErrorUnknown
                                 message:NSLocalizedString(
                                              @"Ejecting failed.", nil)
                                  result:failure]);
        }
    }];
}

#pragma mark - Restore

- (void)restoreFromSource:(DUStorageObject *)source
               destination:(DUStorageObject *)destination
                   options:(NSDictionary *)options
                  progress:(void (^)(double progress, NSString *message))progress
                completion:(void (^)(NSError *error))completion
{
    NSError *gate =
        [self gateForOperation:kDUOperationRestore onObject:destination];
    if (gate == nil && source == nil) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"No restore source was chosen.",
                                             nil));
    }
    if (gate == nil &&
        (source.backendPath.length == 0 ||
         destination.backendPath.length == 0)) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Both source and destination "
                                             @"need device nodes.", nil));
    }
    if (gate == nil &&
        [source.backendPath isEqualToString:destination.backendPath]) {
        gate = DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"Source and destination are "
                                             @"the same device.", nil));
    }
    /* Overlapping nodes, not just identical ones: restoring a whole disk onto
     * one of its own partitions (or a partition onto its parent disk) passes
     * an equality test, and dd then reads and overwrites the same bytes. */
    if (gate == nil) {
        NSString *sourceBase = source.backendPath.lastPathComponent;
        NSString *destinationBase = destination.backendPath.lastPathComponent;
        if ((IsWholeDiskNodeName(destinationBase) &&
             IsNodeOnDisk(sourceBase, destinationBase)) ||
            (IsWholeDiskNodeName(sourceBase) &&
             IsNodeOnDisk(destinationBase, sourceBase))) {
            gate = DUErrorMake(
                DUErrorInvalidArgument,
                NSLocalizedString(@"The destination is part of the source, so "
                                  @"restoring would overwrite the data it is "
                                  @"copying from.", nil));
        }
    }
    unsigned long long totalBytes =
        gate == nil ? [self sizeOfObject:destination] : 0;
    if (gate == nil && totalBytes == 0) {
        gate = DUErrorMake(
            DUErrorUnsupportedOperation,
            NSLocalizedString(@"The destination size is unknown, so restore "
                              @"cannot proceed safely.", nil));
    }
    /* The source has to FIT. Without this check dd happily overwrites a small
     * destination from a large image and only fails when it runs off the end,
     * by which point the destination's table and data are already gone. */
    unsigned long long sourceBytes = 0;
    if (gate == nil) {
        sourceBytes = [self sizeOfObject:source];
        if (sourceBytes == 0 && [source isKindOfClass:[DUDiskImage class]]) {
            sourceBytes = [[[NSFileManager defaultManager]
                attributesOfItemAtPath:((DUDiskImage *)source).path
                                 error:NULL][NSFileSize] unsignedLongLongValue];
        }
        if (sourceBytes == 0) {
            gate = DUErrorMake(
                DUErrorUnsupportedOperation,
                NSLocalizedString(@"The size of the restore source is unknown, "
                                  @"so it cannot be checked against the "
                                  @"destination.", nil));
        } else if (sourceBytes > totalBytes) {
            gate = DUErrorMake(
                DUErrorInvalidArgument,
                [NSString stringWithFormat:
                     NSLocalizedString(
                         @"The source is %.1f GB but the destination is only "
                         @"%.1f GB, so it does not fit.", nil),
                     sourceBytes / (1024.0 * 1024.0 * 1024.0),
                     totalBytes / (1024.0 * 1024.0 * 1024.0)]);
        }
    }

    NSString *busyNode = gate == nil
        ? [self mountedNodeAmong:[self nodesOfSubtree:destination]]
        : nil;
    if (gate == nil && busyNode != nil) {
        gate = DUErrorMake(DUErrorDeviceBusy,
                           [NSString stringWithFormat:
                                NSLocalizedString(
                                    @"%@ is mounted and must be unmounted "
                                    @"before restoring.", nil),
                            busyNode]);
    }

    NSString *ddPath = gate == nil
        ? [DUFreeBSDToolCache pathForTool:@"dd"]
        : nil;
    if (gate == nil && ddPath == nil) {
        gate = DUErrorMake(DUErrorUnsupportedOperation,
                           NSLocalizedString(@"Restoring requires dd, which "
                                             @"is not installed.", nil));
    }
    if (gate != nil) {
        if (completion != NULL) {
            completion(gate);
        }
        return;
    }

    // Image options are reserved; raw device copy is the only mode here.
    (void)options;
    NSString *sourceNode = source.backendPath;
    NSString *destinationNode = destination.backendPath;

    [self spawnWork:^{
        if (progress != NULL) {
            progress(0.0, NSLocalizedString(@"Copying...", nil));
        }
        NSMutableArray<NSString *> *arguments =
            [NSMutableArray arrayWithArray:@[
                [NSString stringWithFormat:@"if=%@", sourceNode],
                [NSString stringWithFormat:@"of=%@", destinationNode],
                @"bs=1M",
                @"status=progress",
            ]];
        /* Stop at the source's length, not at the destination's: dd reading
         * past the end of the image either fails or, worse, keeps writing
         * whatever the device returns. count= keeps the copy honest. */
        [arguments addObject:[NSString stringWithFormat:@"count=%llu",
                                                       sourceBytes / (1024 * 1024)]];
        if (sourceBytes % (1024 * 1024) != 0) {
            [arguments addObject:[NSString stringWithFormat:@"count=%llu",
                                                           (sourceBytes +
                                                            (1024 * 1024) - 1) /
                                                               (1024 * 1024)]];
        }

        // The streamed lines carry running byte counts; the SOURCE size is
        // the denominator, so a small image into a large disk fills the bar
        // instead of stalling near zero and then jumping to full.
        unsigned long long copyBytes = sourceBytes;
        DUProcessResult *result = [self
            blockingStreamedRun:ddPath
                      arguments:arguments
                    lineHandler:^(NSString *line) {
                        unsigned long long copied =
                            [self byteCountFromProgressLine:line];
                        if (copied == 0) {
                            return;
                        }
                        double ratio =
                            (double)copied / (double)copyBytes;
                        if (ratio > 1.0) {
                            ratio = 1.0;
                        }
                        if (progress != NULL) {
                            progress(ratio * 0.98,
                                     NSLocalizedString(@"Copying...", nil));
                        }
                    }];

        if (![self runSucceeded:result]) {
            if (result != nil && result.wasCancelled) {
                if (completion != NULL) {
                    completion(DUErrorMake(DUErrorCancelled,
                                           NSLocalizedString(
                                               @"Restore was cancelled.",
                                               nil)));
                }
                return;
            }
            if (completion != NULL) {
                completion([self toolFailure:DUErrorRestoreFailed
                                     message:NSLocalizedString(
                                                  @"Restoring the image "
                                                  @"failed.", nil)
                                      result:result]);
            }
            return;
        }
        if (progress != NULL) {
            progress(1.0,
                     NSLocalizedString(@"Restore completed.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
    }];
}

#pragma mark - RAID

- (NSError *)createRAIDWithName:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray<DUStorageObject *> *)members
{
    if (name.length == 0 || members.count < 2) {
        return DUErrorMake(DUErrorInvalidArgument,
                           NSLocalizedString(@"A RAID set needs a name and "
                                             @"at least two members.", nil));
    }

    NSDictionary<NSString *, NSString *> *tools = @{
        @"mirror" : @"gmirror",
        @"1" : @"gmirror",
        @"stripe" : @"gstripe",
        @"0" : @"gstripe",
        @"concat" : @"gconcat",
        @"linear" : @"gconcat",
    };
    NSString *tool = tools[level.lowercaseString];
    if (tool == nil) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"RAID level %@ is not supported here.",
                                   nil),
             level]);
    }
    NSString *toolPath = [DUFreeBSDToolCache pathForTool:tool];
    if (toolPath == nil) {
        return DUErrorMake(
            DUErrorUnsupportedOperation,
            [NSString stringWithFormat:
                 NSLocalizedString(@"%@ is not installed.", nil),
             tool]);
    }

    NSMutableArray<NSString *> *memberNodes =
        [NSMutableArray arrayWithCapacity:members.count];
    for (DUStorageObject *member in members) {
        if (member.backendPath.length == 0) {
            return DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(@"A RAID member has no "
                                                 @"device node.", nil));
        }
        [memberNodes addObject:member.backendPath];
    }

    NSString *setName = [self sanitizedLabel:name limit:31];
    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObject:@"label"];
    [arguments addObject:@"-h"];
    [arguments addObject:setName];
    [arguments addObjectsFromArray:memberNodes];

    // gmirror/gstripe/gconcat write metadata onto every member; needs root.
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager]
            runPrivileged:toolPath
                     args:arguments
                  timeout:300.0
                    error:NULL];
    if (![self runSucceeded:result]) {
        return [self toolFailure:DUErrorUnknown
                         message:NSLocalizedString(@"Creating the RAID set "
                                                   @"failed.", nil)
                          result:result];
    }
    return nil;
}


#pragma mark - Image creation

// dd(1) progress lines lead with the running byte count; FreeBSD prints
// "<n> bytes transferred as of <timestamp>" once status=progress is set
// (FreeBSD 13+; older dd simply stays quiet and the bar moves at the
// verification phases instead).
- (NSArray<NSDictionary *> *)imageCreationFormats
{
    NSMutableArray *formats = [NSMutableArray new];
    /* The raw copy is only offered when its mandatory post-copy SHA-256
     * verification can actually run; otherwise the format would fail for
     * every user of a hasher-less system. */
    if ([DUFreeBSDToolCache haveAnyTool: @[ @"sha256", @"sha256sum" ]])
      {
        [formats addObject: @{ kDUFormatIdentifierKey : @"raw",
                               kDUFormatDisplayNameKey :
                                   NSLocalizedString(@"Raw disk image (.img)",
                                                     nil) }];
      }
    if ([DUFreeBSDToolCache haveTool: @"gzip"])
      {
        [formats addObject: @{ kDUFormatIdentifierKey : @"gz",
                               kDUFormatDisplayNameKey :
                                   NSLocalizedString(
                                       @"Gzipped raw image (.img.gz)",
                                       nil) }];
      }
    if ([DUFreeBSDToolCache haveTool: @"qemu-img"])
      {
        for (NSString *format in @[ @"qcow2", @"vhd", @"vdi" ])
          {
            [formats addObject: @{ kDUFormatIdentifierKey : format,
                                   kDUFormatDisplayNameKey :
                                       [NSString stringWithFormat:
                                           NSLocalizedString(
                                               @"QEMU %@ (via qemu-img)",
                                               nil),
                                           format.uppercaseString] }];
          }
      }
    return formats;
}

// Resolves any imagerable object to its byte source and size.
- (NSString *)imageSourceForObject:(DUStorageObject *)object
                            bytes:(unsigned long long *)bytesOut
{
    DUStorageObject *source = object;
    if ([source isKindOfClass:[DUStorageVolume class]])
      {
        source = source.parent ?: source;
      }
    NSString *path = source.backendPath;
    unsigned long long bytes = 0;
    if (path.length == 0)
      {
        return nil;
      }
    if ([source isKindOfClass:[DUStorageDevice class]])
      {
        bytes = ((DUStorageDevice *)source).capacityBytes;
      }
    else if ([source isKindOfClass:[DUPartition class]])
      {
        bytes = ((DUPartition *)source).sizeBytes;
      }
    else if ([source isKindOfClass:[DUStorageVolume class]])
      {
        bytes = ((DUStorageVolume *)source).capacityBytes;
      }
    else if ([source isKindOfClass:[DUDiskImage class]])
      {
        bytes = ((DUDiskImage *)source).sizeBytes;
      }
    if (bytes == 0)
      {
        return nil;
      }
    *bytesOut = bytes;
    return path;
}

/* SHA-256 hex digest of the first sizeBytes of `path`, computed with the
 * base-system sha256(1)/coreutils sha256sum(1) through the elevated
 * streaming runner (device nodes are root-only). The digest is parsed
 * from whichever output variant the installed tool produces. */
- (NSString *)sha256HexForPath:(NSString *)path
                     sizeBytes:(unsigned long long)sizeBytes
                      progress:(void (^)(double))progress
{
    NSString *tool = [DUFreeBSDToolCache pathForTool: @"sha256"]
        ?: [DUFreeBSDToolCache pathForTool: @"sha256sum"];
    if (tool == nil || sizeBytes == 0)
      {
        return nil;
      }
    NSMutableArray *arguments =
        [NSMutableArray arrayWithObject: path];
    /* BSD sha256 defaults to labelled output; sha256sum needs no flag. */
    if (![tool hasSuffix: @"sha256sum"])
      {
        [arguments insertObject: @"-q" atIndex: 0];
      }

    __block NSMutableString *digest = [NSMutableString string];
    DUProcessResult *result = [self blockingStreamedRun: tool
                                              arguments: arguments
                                            lineHandler:^(NSString *line)
      {
        NSString *trimmed = [DUParsing trimmedString: line];
        if ([trimmed length] >= 64)
          {
            [digest setString: [[trimmed substringToIndex: 64]
                lowercaseString]];
          }
        if (progress != NULL)
          {
            progress(1.0);
          }
      }];
    if (![self runSucceeded: result] || [digest length] != 64)
      {
        return nil;
      }
    return digest;
}

- (void)createImageFromObject:(DUStorageObject *)object
                      options:(NSDictionary *)options
                     progress:(void (^)(double, NSString *))progress
                   completion:(void (^)(NSError *))completion
{
    /* Verification after the copy is mandatory: the flow hashes the source
     * and the written bytes and fails on any mismatch. Without a SHA-256
     * tool that ending is certain, so refuse before writing gigabytes. */
    if (![DUFreeBSDToolCache haveAnyTool: @[ @"sha256", @"sha256sum" ]])
      {
        if (completion != NULL)
          {
            completion(DUErrorMake(DUErrorUnsupportedOperation,
                NSLocalizedString(@"No SHA-256 tool (sha256 or sha256sum) "
                                  @"is installed, so the image cannot be "
                                  @"verified after writing.", nil)));
          }
        return;
      }

    [self spawnWork:^{
      unsigned long long sourceBytes = 0;
      NSString *sourcePath = [self imageSourceForObject: object
                                                  bytes: &sourceBytes];
      NSString *targetPath = options[@"path"];
      NSString *format = options[@"format"];
      if (sourcePath == nil || targetPath.length == 0 || format == nil)
        {
          completion(DUErrorMake(DUErrorInvalidArgument,
              NSLocalizedString(@"Missing image parameters.", nil)));
          return;
        }
      targetPath = [targetPath stringByExpandingTildeInPath];
      if ([[NSFileManager defaultManager] fileExistsAtPath: targetPath])
        {
          completion(DUErrorMake(DUErrorInvalidArgument,
              NSLocalizedString(@"The image file already exists.", nil)));
          return;
        }

      BOOL compressed = [format isEqualToString: @"gz"];
      BOOL convertAfter = ![format isEqualToString: @"raw"] && !compressed;
      /* Every non-raw target is produced from a raw intermediate, then
       * finished. For "gz" that means a sibling raw file is compressed into
       * the real target afterwards: writing dd's output straight to the
       * .img.gz left uncompressed bytes in a file named as a gzip archive,
       * which then failed its own gzip -t and reported a checksum mismatch
       * after copying the entire source. */
      NSString *rawPath = [targetPath stringByAppendingPathExtension:
                                               @"tmp-raw"];
      NSString *gzip = compressed
          ? [DUFreeBSDToolCache pathForTool: @"gzip"]
          : nil;
      if (compressed && gzip == nil)
        {
          completion(DUErrorMake(DUErrorUnsupportedOperation,
              NSLocalizedString(@"The gzip tool is not installed, so a "
                                @"compressed image cannot be created.", nil)));
          return;
        }

      NSString *dd = [DUFreeBSDToolCache pathForTool: @"dd"];
      if (dd == nil)
        {
          completion(DUErrorMake(DUErrorUnsupportedOperation,
              NSLocalizedString(@"The required tool dd is not installed.",
                                nil)));
          return;
        }

      progress(0.02,
          NSLocalizedString(@"Copying device to image...", nil));
      NSMutableArray *ddArguments = [NSMutableArray arrayWithObjects:
          [@"if=" stringByAppendingString: sourcePath],
          [@"of=" stringByAppendingString: rawPath],
          @"bs=1m", nil];
      /* FreeBSD dd understands status=progress since 13; unknown operands
       * on older world builds surface as a normal tool failure. */
      [ddArguments addObject: @"status=progress"];

      __block double copiedFraction = 0.0;
      DUProcessResult *result = [self blockingStreamedRun: dd
                                                arguments: ddArguments
                                              lineHandler:^(NSString *line)
        {
          unsigned long long copied = [self byteCountFromProgressLine: line];
          if (copied > 0 && sourceBytes > 0)
            {
              copiedFraction = MIN(1.0, (double)copied /
                  (double)sourceBytes);
              if (progress != NULL)
                progress(copiedFraction * 0.5, line);
            }
        }];
      if (![self runSucceeded: result])
        {
          [[NSFileManager defaultManager] removeItemAtPath:
              rawPath error: NULL];
          completion([self toolFailure: DUErrorRestoreFailed
                               message: NSLocalizedString(
                                            @"Writing the image failed.",
                                            nil)
                                result: result]);
          return;
        }

      /* Verify the raw intermediate against the source before spending time
       * on the final format: a byte-for-byte match here is the strongest
       * statement the flow can make, and it holds for raw, gzip and
       * converted targets alike. */
      progress(0.5, NSLocalizedString(@"Hashing the source...", nil));
      NSString *sourceDigest =
          [self sha256HexForPath: sourcePath
                       sizeBytes: sourceBytes
                        progress: ^(double fraction) {
                            if (progress != NULL)
                              progress(0.5 + fraction * 0.125,
                                  NSLocalizedString(
                                      @"Hashing the source...", nil));
                          }];

      progress(0.75,
          NSLocalizedString(@"Re-reading written data...", nil));
      NSString *writtenDigest =
          [self sha256HexForPath: rawPath
                       sizeBytes: sourceBytes
                        progress: ^(double fraction) {
                            if (progress != NULL)
                              progress(0.75 + fraction * 0.15,
                                  NSLocalizedString(
                                      @"Re-reading written data...", nil));
                        }];

      if (writtenDigest == nil ||
          ![writtenDigest isEqualToString: sourceDigest])
        {
          [[NSFileManager defaultManager] removeItemAtPath:
              rawPath error: NULL];
          completion(DUErrorMake(DUErrorVerificationFailed,
              NSLocalizedString(@"Checksum mismatch: the written image "
                                @"does not match the source device.",
                                nil)));
          return;
        }

      /* Finish the target: compress, convert, or keep the raw file. */
      if (compressed)
        {
          progress(0.9, NSLocalizedString(@"Compressing image...", nil));
          NSData *archive = [self binaryStandardOutputOf: gzip
                                               arguments: @[ @"-c", rawPath ]];
          [[NSFileManager defaultManager] removeItemAtPath:
              rawPath error: NULL];
          if (archive.length == 0)
            {
              completion(DUErrorMake(DUErrorUnknown,
                  NSLocalizedString(@"Compressing the image failed.", nil)));
              return;
            }
          if (![archive writeToFile: targetPath atomically: YES])
            {
              completion(DUErrorMake(DUErrorFilesystemError,
                  NSLocalizedString(@"The compressed image could not be "
                                    @"written to the chosen location.", nil)));
              return;
            }
          progress(0.97,
              NSLocalizedString(@"Verifying archive integrity...", nil));
          DUProcessResult *test =
              [self blockingStreamedRun: gzip
                              arguments: @[ @"-t", targetPath ]
                            lineHandler: nil];
          if (![self runSucceeded: test])
            {
              completion([self toolFailure: DUErrorVerificationFailed
                                   message: NSLocalizedString(
                                                @"The compressed image is not "
                                                @"a valid archive.", nil)
                                    result: test]);
              return;
            }
        }
      else if (convertAfter)
        {
          progress(0.9, NSLocalizedString(@"Converting image...", nil));
          NSString *qemuImg =
              [DUFreeBSDToolCache pathForTool: @"qemu-img"];
          if (qemuImg == nil)
            {
              [[NSFileManager defaultManager] removeItemAtPath:
                  rawPath error: NULL];
              completion(DUErrorMake(DUErrorUnsupportedOperation,
                  NSLocalizedString(@"The qemu-img tool is not installed, so "
                                    @"this image format cannot be produced.",
                                    nil)));
              return;
            }
          DUProcessResult *conversion =
              [self blockingStreamedRun: qemuImg
                              arguments: @[ @"convert", @"-O", format,
                                            rawPath, targetPath ]
                            lineHandler: nil];
          [[NSFileManager defaultManager] removeItemAtPath:
              rawPath error: NULL];
          if (![self runSucceeded: conversion])
            {
              completion([self toolFailure: DUErrorUnknown
                                   message: NSLocalizedString(
                                                @"Converting the image "
                                                @"failed.", nil)
                                    result: conversion]);
              return;
            }
        }
      else
        {
          /* Plain raw: the intermediate IS the target. */
          if (![[NSFileManager defaultManager] moveItemAtPath: rawPath
                                                      toPath: targetPath
                                                       error: NULL])
            {
              completion(DUErrorMake(DUErrorFilesystemError,
                  NSLocalizedString(@"The image could not be moved into "
                                    @"place.", nil)));
              return;
            }
        }

      progress(1.0,
          NSLocalizedString(@"Image created successfully.", nil));
      completion(nil);
    }];
}

// Re-runs a compressor and returns its BINARY stdout. gzip -c writes the
// archive to stdout, which the streaming runner merges with stderr and so
// cannot hand back as bytes; the copy is only ever a temporary artifact.
- (NSData *)binaryStandardOutputOf:(NSString *)path
                        arguments:(NSArray<NSString *> *)arguments
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError: NULL])
      {
        return nil;
      }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0)
      {
        return nil;
      }
    return data;
}

#pragma mark - Image conversion, resizing, burning

// Picks the first installed cdrecord-family burning tool. All of these are
// GPL and therefore run as a separate process per LIBRARIES.md section 26,
// never linked or dlopen'd. Returns nil when none are present so the
// capability report stays honest.
- (NSString *)burnToolPath
{
    for (NSString *candidate in @[ @"cdrecord", @"wodim", @"xorriso",
                                    @"growisofs" ]) {
        NSString *path = [DUFreeBSDToolCache pathForTool:candidate];
        if (path != nil) {
            return path;
        }
    }
    return nil;
}

// cdrecord and its cdrtools derivatives share one invocation shape;
// growisofs and xorriso (as cdrecord) differ enough to need their own
// argument layout. All write the image to the drive node.
- (NSArray<NSString *> *)burnArgumentsForTool:(NSString *)tool
                                   imagePath:(NSString *)imagePath
                                    drivePath:(NSString *)drivePath
{
    NSString *base = tool.lastPathComponent;
    if ([base isEqualToString:@"xorriso"]) {
        return @[ @"-as", @"cdrecord", @"-v",
                  [NSString stringWithFormat:@"dev=%@", drivePath],
                  @"-data", imagePath ];
    }
    if ([base isEqualToString:@"growisofs"]) {
        return @[ @"-dvd-compat",
                  [NSString stringWithFormat:@"%@=%@", drivePath, imagePath] ];
    }
    return @[ @"-v",
              [NSString stringWithFormat:@"dev=%@", drivePath],
              imagePath ];
}

#pragma mark - Blank and folder image creation

- (unsigned long long)folderSizeAtPath:(NSString *)folder
{
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:folder];
    for (NSString *entry in enumerator) {
        NSString *full = [folder stringByAppendingPathComponent:entry];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        if ([[attrs fileType] isEqualToString:NSFileTypeRegular]) {
            total += [attrs fileSize];
        }
    }
    return total;
}

// Attaches a raw image file via mdconfig and returns the /dev/mdN node, or
// nil on failure. The caller mounts, copies and later detaches it.
// mdconfig(8) creates a memory-backed disk provider, which needs root; run
// unprivileged it fails with "must be superuser" and every image-mount path
// in the app dies at this one call.
- (NSString *)attachImageFile:(NSString *)path
{
    NSString *mdconfig = [DUFreeBSDToolCache pathForTool:@"mdconfig"];
    if (mdconfig == nil) {
        return nil;
    }
    DUProcessResult *result =
        [[DUAuthorizationManager sharedManager]
            runPrivileged:mdconfig
                     args:@[ @"-a", @"-f", path ]
                  timeout:120.0
                    error:NULL];
    if (![self runSucceeded:result]) {
        return nil;
    }
    /* mdconfig(8) prints a bare device name ("md5") with no newline on some
     * builds and "md5\n" on others; mdconfig -l on a loaded system lists
     * already-attached devices too, so the newest name the command reported
     * is what belongs to this file. */
    NSString *node = [DUParsing trimmedString:result.standardOutput];
    if (node.length == 0) {
        return nil;
    }
    if (![node hasPrefix:@"/dev/"]) {
        node = [@"/dev/" stringByAppendingString:node];
    }
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:node]) {
        return nil;
    }
    return node;
}

- (void)detachImageNode:(NSString *)node
{
    NSString *mdconfig = [DUFreeBSDToolCache pathForTool:@"mdconfig"];
    if (mdconfig == nil) {
        return;
    }
    [[DUAuthorizationManager sharedManager]
        runPrivileged:mdconfig
                 args:@[ @"-d", @"-u", node ]
              timeout:120.0
                error:NULL];
}

// Whether `path` is a filesystem root right now. A path that only LOOKS
// like a mount point is an ordinary directory as far as any copy into it is
// concerned, so every attach/mount/copy sequence has to check this before it
// writes anything.
- (BOOL)pathIsMountRoot:(NSString *)path
{
    if (path.length == 0) {
        return NO;
    }
    // Fast enumeration over a dictionary yields its KEYS, which here are
    // device paths; the values are the records that carry the mount point, so
    // the table is read once and its values enumerated.
    NSDictionary<NSString *, NSDictionary *> *table =
        [DUFreeBSDGEOMAdapter currentMountTable];
    for (NSDictionary *entry in [table allValues]) {
        if ([entry[@"mountPoint"] isEqualToString:path]) {
            return YES;
        }
    }
    return NO;
}

// Detach a path that may or may not be mounted; used on the error paths so a
// half-attached image does not leak a filesystem.
- (void)unmountQuietly:(NSString *)path
{
    NSString *umount = [DUFreeBSDToolCache pathForTool:@"umount"];
    if (umount == nil || path.length == 0) {
        return;
    }
    [[DUAuthorizationManager sharedManager]
        runPrivileged:umount
                 args:@[ path ]
              timeout:120.0
                error:NULL];
}

- (void)createBlankImageAtPath:(NSString *)path
                           size:(unsigned long long)bytes
                         format:(NSString *)format
                       progress:(void (^)(double, NSString *))progress
                     completion:(void (^)(NSError *))completion
{
    [self spawnWork:^{
        progress(0.0, NSLocalizedString(@"Creating blank image...", nil));
        NSError *error = nil;
        if ([format isEqualToString:@"raw"]) {
            NSString *truncate =
                [DUFreeBSDToolCache pathForTool:@"truncate"];
            if (truncate == nil) {
                completion(
                    [self toolFailure:DUErrorBackendUnavailable
                              message:NSLocalizedString(
                                          @"The truncate tool is missing.",
                                          nil)
                               result:nil]);
                return;
            }
            NSError *launchError = nil;
            DUProcessResult *result = [DUProcessRunner
                runExecutable:truncate
                   arguments:@[
                       @"-s", [NSString stringWithFormat:@"%llu", bytes],
                       path
                   ]
                       error:&launchError];
            if (![self runSucceeded:result] || launchError != nil) {
                error = launchError
                            ?: [self toolFailure:DUErrorFilesystemError
                                          message:NSLocalizedString(
                                                      @"The blank image "
                                                      @"could not be created.",
                                                      nil)
                                           result:result];
            }
        } else {
            NSString *qemu =
                [DUFreeBSDToolCache pathForTool:@"qemu-img"];
            if (qemu == nil) {
                completion([self
                    toolFailure:DUErrorUnsupportedOperation
                              message:NSLocalizedString(
                                          @"Creating this image format "
                                          @"requires qemu-img.",
                                          nil)
                               result:nil]);
                return;
            }
            NSError *launchError = nil;
            DUProcessResult *result = [DUProcessRunner
                runExecutable:qemu
                   arguments:@[
                       @"create", @"-f", format, path,
                       [NSString stringWithFormat:@"%llu", bytes]
                   ]
                       error:&launchError];
            if (![self runSucceeded:result] || launchError != nil) {
                error = launchError
                            ?: [self toolFailure:DUErrorFilesystemError
                                          message:NSLocalizedString(
                                                      @"The blank image "
                                                      @"could not be created.",
                                                      nil)
                                           result:result];
            }
        }
        if (error == nil) {
            progress(1.0,
                     NSLocalizedString(@"Blank image created.", nil));
        }
        completion(error);
    }];
}

- (void)createImageFromFolder:(NSString *)folderPath
                  destination:(NSString *)path
                  filesystem:(NSString *)filesystem
                    progress:(void (^)(double, NSString *))progress
                  completion:(void (^)(NSError *))completion
{
    (void)filesystem;
    [self spawnWork:^{
        unsigned long long content = [self folderSizeAtPath:folderPath];
        unsigned long long size = content + content / 10 + 16 * 1024 * 1024;
        progress(0.05,
                 NSLocalizedString(@"Creating image container...", nil));
        NSString *truncate = [DUFreeBSDToolCache pathForTool:@"truncate"];
        if (truncate == nil) {
            completion([self toolFailure:DUErrorBackendUnavailable
                                  message:NSLocalizedString(
                                              @"The truncate tool is missing.",
                                              nil)
                                   result:nil]);
            return;
        }
        NSError *launchError = nil;
        DUProcessResult *createResult = [DUProcessRunner
            runExecutable:truncate
               arguments:@[
                   @"-s", [NSString stringWithFormat:@"%llu", size], path
               ]
                   error:&launchError];
        if (![self runSucceeded:createResult] || launchError != nil) {
            completion(launchError
                           ?: [self toolFailure:DUErrorFilesystemError
                                         message:NSLocalizedString(
                                                     @"The image container "
                                                     @"could not be created.",
                                                     nil)
                                          result:createResult]);
            return;
        }
        progress(0.2, NSLocalizedString(@"Formatting image...", nil));
        NSString *newfs =
            [DUFreeBSDToolCache pathForTool:@"newfs_msdos"];
        if (newfs == nil) {
            completion([self toolFailure:DUErrorBackendUnavailable
                                  message:NSLocalizedString(
                                              @"The FAT formatting tool is "
                                              @"missing.",
                                              nil)
                                   result:nil]);
            return;
        }
        DUProcessResult *formatResult = [DUProcessRunner
            runExecutable:newfs
               arguments:@[ path ]
                   error:&launchError];
        if (![self runSucceeded:formatResult] || launchError != nil) {
            completion(launchError
                           ?: [self toolFailure:DUErrorFilesystemError
                                         message:NSLocalizedString(
                                                     @"The image filesystem "
                                                     @"could not be formatted.",
                                                     nil)
                                          result:formatResult]);
            return;
        }
        progress(0.35, NSLocalizedString(@"Mounting image...", nil));
        NSString *node = [self attachImageFile:path];
        if (node == nil) {
            completion([self toolFailure:DUErrorMountError
                                  message:NSLocalizedString(
                                              @"The folder image could not "
                                              @"be attached.",
                                              nil)
                                   result:nil]);
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *mountPoint = [NSString
            stringWithFormat:@"/tmp/du_img_%@",
                             [[NSProcessInfo processInfo]
                                 globallyUniqueString]];
        [fm createDirectoryAtPath:mountPoint
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        NSString *mount = [DUFreeBSDToolCache pathForTool:@"mount"];
        /* mdconfig reports the device as a bare name ("md5"), and mount(8)
         * needs the full node: given "md5" it reports "No such file or
         * directory", exits nonzero, and the mount point stays a plain
         * directory - so the copy that follows silently writes the folder
         * into /tmp instead of into the image. */
        NSString *device = [node hasPrefix:@"/dev/"]
            ? node
            : [@"/dev/" stringByAppendingString:node];
        NSArray<NSString *> *mountArguments =
            @[ device, mountPoint ];
        // mount(8) attaches a filesystem for the whole session; needs root.
        DUProcessResult *mountResult =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:mount
                         args:mountArguments
                      timeout:300.0
                        error:&launchError];
        if (![self runSucceeded:mountResult] || launchError != nil) {
            [self detachImageNode:node];
            completion(launchError
                           ?: [self toolFailure:DUErrorMountError
                                         message:NSLocalizedString(
                                                     @"The folder image could "
                                                     @"not be mounted.",
                                                     nil)
                                          result:mountResult]);
            return;
        }
        /* mount(8) can exit 0 while nothing is attached - a device node the
         * kernel does not recognise is reported as "No such file or
         * directory" by some paths and the mount point stays a plain
         * directory. `cp -a` into a plain directory succeeds and writes
         * everything into the temporary folder, so the image is then
         * declared created with an empty filesystem and the user's data is
         * gone. Refuse before copying unless the path really is a mount
         * root. */
        if (![self pathIsMountRoot:mountPoint]) {
            [self unmountQuietly:mountPoint];
            [self detachImageNode:node];
            completion([self toolFailure:DUErrorMountError
                                 message:NSLocalizedString(
                                             @"The folder image could not be "
                                             @"mounted: nothing was attached "
                                             @"at the mount point.",
                                             nil)
                                  result:mountResult]);
            return;
        }
        progress(0.5,
                 NSLocalizedString(@"Copying files into image...", nil));
        NSString *cp = @"/bin/cp";
        DUProcessResult *copyResult = [DUProcessRunner
            runExecutable:cp
               arguments:@[
                   @"-a",
                   [folderPath stringByAppendingPathComponent:@"."],
                   mountPoint
               ]
                   error:&launchError];
        // umount detaches the image again; needs root like the mount did.
        NSString *umount = [DUFreeBSDToolCache pathForTool:@"umount"];
        if (umount != nil) {
            [[DUAuthorizationManager sharedManager]
                runPrivileged:umount
                         args:@[ mountPoint ]
                      timeout:300.0
                        error:NULL];
        }
        [self detachImageNode:node];
        if (![self runSucceeded:copyResult] || launchError != nil) {
            completion(launchError
                           ?: [self toolFailure:DUErrorFilesystemError
                                         message:NSLocalizedString(
                                                     @"The folder could not "
                                                     @"be copied into the "
                                                     @"image.",
                                                     nil)
                                          result:copyResult]);
            return;
        }
        progress(1.0, NSLocalizedString(@"Folder image created.", nil));
        completion(nil);
    }];
}

- (void)mountFileImageAtPath:(NSString *)path
                  completion:(void (^)(NSError *, NSString *))completion
{
    [self spawnWork:^{
        NSString *node = [self attachImageFile:path];
        if (node == nil) {
            completion(
                [self toolFailure:DUErrorMountError
                          message:NSLocalizedString(
                                      @"The disk image could not be attached.",
                                      nil)
                           result:nil],
                nil);
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *mountPoint = [NSString
            stringWithFormat:@"/tmp/du_img_%@",
                             [[NSProcessInfo processInfo]
                                 globallyUniqueString]];
        [fm createDirectoryAtPath:mountPoint
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
        NSError *launchError = nil;
        /* mdconfig(8) prints a bare name ("md5") and mount(8) needs the full
         * node: given the bare name it exits nonzero with "No such file or
         * directory" and the mount point stays a plain directory. The name is
         * normalised once, in -attachImageFile:, so this path already has a
         * /dev/... node. */
        /* No -t: the image may hold UFS, FAT or an ISO, and hardcoding
         * "msdos" made mount(8) fail on every other filesystem (the FreeBSD
         * spelling is msdosfs anyway, so the old argument could not work at
         * all). Let mount(8) probe the medium. */
        // mount(8) attaches a filesystem for the whole session; needs root.
        DUProcessResult *mountResult =
            [[DUAuthorizationManager sharedManager]
                runPrivileged:[DUFreeBSDToolCache pathForTool:@"mount"]
                         args:@[ node, mountPoint ]
                      timeout:300.0
                        error:&launchError];
        if (![self runSucceeded:mountResult] || launchError != nil) {
            [self detachImageNode:node];
            completion(
                launchError
                    ?: [self toolFailure:DUErrorMountError
                                  message:NSLocalizedString(
                                              @"The disk image could not be "
                                              @"mounted.",
                                              nil)
                                   result:mountResult],
                nil);
            return;
        }
        /* mount(8) exiting 0 is not proof that anything was attached: a
         * device node the kernel cannot resolve leaves the mount point a
         * plain directory, which then reads as an empty volume in the
         * browser. Detach and report rather than hand back a path that is
         * not a filesystem. */
        if (![self pathIsMountRoot:mountPoint]) {
            [self unmountQuietly:mountPoint];
            [self detachImageNode:node];
            completion(
                [self toolFailure:DUErrorMountError
                          message:NSLocalizedString(
                                      @"The disk image could not be mounted: "
                                      @"nothing was attached at the mount "
                                      @"point.",
                                      nil)
                           result:mountResult],
                nil);
            return;
        }
        completion(nil, mountPoint);
    }];
}

- (void)convertImage:(DUStorageObject *)image
             options:(NSDictionary *)options
            progress:(void (^)(double, NSString *))progress
          completion:(void (^)(NSError *))completion
{
    NSString *sourcePath = ((DUDiskImage *)image).path;
    NSString *targetPath = options[@"path"];
    NSString *format = options[@"format"];
    if (sourcePath.length == 0 || targetPath.length == 0 ||
        format.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    // qemu-img runs as an ordinary unprivileged process: it only reads the
    // source file and writes the destination file (LIBRARIES.md section 3).
    NSString *qemuImg = [DUFreeBSDToolCache pathForTool:@"qemu-img"];
    if (qemuImg == nil) {
        completion(DUErrorMake(DUErrorUnsupportedOperation,
                               NSLocalizedString(
                                   @"Converting images requires the qemu-img "
                                    @"tool.", nil)));
        return;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:targetPath]) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"A file already exists at the "
                                    @"destination.", nil)));
        return;
    }
    [self spawnWork:^{
        progress(0.1, NSLocalizedString(@"Converting image...", nil));
        NSError *launchError = nil;
        DUProcessResult *result =
            [DUProcessRunner runExecutable:qemuImg
                                 arguments:@[ @"convert", @"-O", format,
                                              sourcePath, targetPath ]
                                     error:&launchError];
        if (launchError != nil) {
            [[NSFileManager defaultManager] removeItemAtPath:targetPath
                                                       error:NULL];
            completion(launchError);
            return;
        }
        if (![self runSucceeded:result]) {
            [[NSFileManager defaultManager] removeItemAtPath:targetPath
                                                       error:NULL];
            completion([self toolFailure:DUErrorUnknown
                                 message:NSLocalizedString(
                                             @"The image conversion failed.",
                                             nil)
                                  result:result]);
            return;
        }
        progress(1.0,
                 NSLocalizedString(@"Image converted successfully.", nil));
        completion(nil);
    }];
}

- (void)resizeImage:(DUStorageObject *)image
            options:(NSDictionary *)options
           progress:(void (^)(double, NSString *))progress
         completion:(void (^)(NSError *))completion
{
    NSString *sourcePath = ((DUDiskImage *)image).path;
    NSNumber *delta = options[@"deltaBytes"];
    if (sourcePath.length == 0 || delta == nil) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing image parameters.", nil)));
        return;
    }
    long long deltaBytes = delta.longLongValue;
    if (deltaBytes == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(@"The resize amount must not "
                                                  @"be zero.", nil)));
        return;
    }
    NSString *qemuImg = [DUFreeBSDToolCache pathForTool:@"qemu-img"];
    if (qemuImg == nil) {
        completion(DUErrorMake(DUErrorUnsupportedOperation,
                               NSLocalizedString(
                                   @"Resizing images requires the qemu-img "
                                    @"tool.", nil)));
        return;
    }
    [self spawnWork:^{
        progress(0.1, NSLocalizedString(@"Resizing image...", nil));
        // qemu-img speaks a signed suffix: "+<bytes>" grows, "-<bytes>"
        // shrinks.
        NSString *deltaSpec =
            [NSString stringWithFormat:@"%c%lld",
                                       deltaBytes > 0 ? '+' : '-',
                                       deltaBytes > 0 ? deltaBytes
                                                      : -deltaBytes];
        NSError *launchError = nil;
        DUProcessResult *result =
            [DUProcessRunner runExecutable:qemuImg
                                 arguments:@[ @"resize", sourcePath,
                                              deltaSpec ]
                                     error:&launchError];
        if (launchError != nil) {
            completion(launchError);
            return;
        }
        if (![self runSucceeded:result]) {
            completion([self toolFailure:DUErrorUnknown
                                 message:NSLocalizedString(
                                             @"The image could not be "
                                              @"resized.", nil)
                                  result:result]);
            return;
        }
        progress(1.0,
                 NSLocalizedString(@"Image resized successfully.", nil));
        completion(nil);
    }];
}

- (void)burnImage:(DUStorageObject *)image
          toObject:(DUStorageObject *)opticalDrive
          progress:(void (^)(double, NSString *))progress
         completion:(void (^)(NSError *))completion
{
    NSString *imagePath = ((DUDiskImage *)image).path;
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    if (imagePath.length == 0 || drivePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing burn parameters.", nil)));
        return;
    }
    NSString *tool = [self burnToolPath];
    if (tool == nil) {
        completion(DUErrorMake(DUErrorBackendUnavailable,
                               NSLocalizedString(
                                   @"No optical burning tool is installed "
                                    @"(cdrecord, wodim, xorriso or "
                                    @"growisofs).", nil)));
        return;
    }
    NSArray<NSString *> *arguments =
        [self burnArgumentsForTool:tool.lastPathComponent
                         imagePath:imagePath
                          drivePath:drivePath];
    [self spawnWork:^{
        progress(0.05, NSLocalizedString(@"Writing disc...", nil));
        DUProcessResult *result =
            [self blockingStreamedRun:tool
                            arguments:arguments
                          lineHandler:^(NSString *line) {
                // cdrecord/growisofs print percentage progress lines;
                // surface them so the operation log moves during the burn.
                double fraction = [self burnProgressFromLine:line];
                if (fraction > 0.0 && progress != NULL) {
                    progress(fraction,
                             NSLocalizedString(@"Writing disc...", nil));
                }
            }];
        if (![self runSucceeded:result]) {
            completion([self toolFailure:DUErrorUnknown
                                 message:NSLocalizedString(
                                             @"Burning the disc failed.", nil)
                                  result:result]);
            return;
        }
        progress(1.0, NSLocalizedString(@"Disc burned successfully.", nil));
        completion(nil);
    }];
}

// cdrecord emits "XX.X% done" lines; growisofs/xorriso are quieter but a
// non-zero fraction here only updates the bar, so a missed parse simply
// leaves the bar at its last value rather than jumping backwards.
- (double)burnProgressFromLine:(NSString *)line
{
    NSRange percent = [line rangeOfString:@"%"];
    if (percent.location == NSNotFound) {
        return 0.0;
    }
    NSRange start = [line rangeOfString:@" "
                                options:NSBackwardsSearch
                                  range:NSMakeRange(0, percent.location)];
    NSUInteger from = start.location == NSNotFound ? 0 : start.location + 1;
    NSString *number =
        [line substringWithRange:NSMakeRange(from, percent.location - from)];
    double value = [number doubleValue];
    if (value <= 0.0 || value > 100.0) {
        return 0.0;
    }
    return MIN(0.95, value / 100.0);
}

#pragma mark - Disc blank and verify (optical)

// Mirrors the Linux backend: xorriso/cdrecord/wodim blank the rewritable
// medium; growisofs cannot blank, so it is intentionally omitted here.
- (void)blankOpticalDisc:(DUStorageObject *)opticalDrive
                options:(NSDictionary *)options
               progress:(void (^)(double, NSString *))progress
             completion:(void (^)(NSError *))completion
{
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    if (drivePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing disc drive.", nil)));
        return;
    }
    NSString *method = options[kDUDiscBlankMethodKey] ?: kDUDiscBlankFastKey;
    NSString *mode = [method isEqualToString:kDUDiscBlankAllKey]
        ? @"all" : @"fast";
    NSString *tool = nil;
    for (NSString *candidate in @[ @"xorriso", @"wodim", @"cdrecord" ]) {
        NSString *path = [DUFreeBSDToolCache pathForTool:candidate];
        if (path != nil) {
            tool = path;
            break;
        }
    }
    if (tool == nil) {
        completion(DUErrorMake(
            DUErrorBackendUnavailable,
            NSLocalizedString(
                @"No optical blanking tool is installed "
                @"(xorriso, wodim or cdrecord).", nil)));
        return;
    }
    NSArray<NSString *> *arguments;
    NSString *last = tool.lastPathComponent;
    if ([last isEqualToString:@"xorriso"]) {
        arguments = @[ @"-as", @"cdrecord", @"-v",
                      [NSString stringWithFormat:@"blank=%@", mode],
                      [NSString stringWithFormat:@"dev=%@", drivePath] ];
    } else {
        arguments = @[ @"-v",
                      [NSString stringWithFormat:@"blank=%@", mode],
                      [NSString stringWithFormat:@"dev=%@", drivePath] ];
    }
    progress(0.05, NSLocalizedString(@"Blanking disc...", nil));
    [self spawnWork:^{
        DUProcessResult *result =
            [self blockingStreamedRun:tool
                            arguments:arguments
                          lineHandler:^(NSString *line) {
                double fraction = [self burnProgressFromLine:line];
                if (fraction > 0.0 && progress != NULL) {
                    progress(fraction,
                             NSLocalizedString(@"Blanking disc...", nil));
                }
            }];
        if (![self runSucceeded:result]) {
            completion([self toolFailure:DUErrorEraseFailed
                                 message:NSLocalizedString(
                                     @"Blanking the disc failed.", nil)
                                  result:result]);
            return;
        }
        progress(1.0, NSLocalizedString(@"Disc blanked successfully.", nil));
        completion(nil);
    }];
}

// Reads the burned disc back and compares it byte-for-byte against the
// source image with cmp; exit 0 means a match, anything else a mismatch or
// read error (both surfaced as a verification failure).
- (void)verifyDisc:(DUStorageObject *)opticalDrive
      againstImage:(DUStorageObject *)image
          progress:(void (^)(double, NSString *))progress
        completion:(void (^)(NSError *))completion
{
    NSString *drivePath = ((DUStorageDevice *)opticalDrive).devicePath
        ?: opticalDrive.backendPath;
    NSString *imagePath = ((DUDiskImage *)image).path;
    if (drivePath.length == 0 || imagePath.length == 0) {
        completion(DUErrorMake(DUErrorInvalidArgument,
                               NSLocalizedString(
                                   @"Missing verify parameters.", nil)));
        return;
    }
    NSString *cmp = [DUFreeBSDToolCache pathForTool:@"cmp"] ?: @"/usr/bin/cmp";
    progress(0.1, NSLocalizedString(@"Reading disc back...", nil));
    [self spawnWork:^{
        DUProcessResult *result =
            [self blockingStreamedRun:cmp
                            arguments:@[ drivePath, imagePath ]
                          lineHandler:^(NSString *line) { (void)line; }];
        if (![self runSucceeded:result]) {
            completion([self toolFailure:DUErrorVerificationFailed
                                 message:NSLocalizedString(
                                     @"The disc does not match the image.",
                                     nil)
                                  result:result]);
            return;
        }
        progress(1.0, NSLocalizedString(
                         @"Disc verified: data matches the image.", nil));
        completion(nil);
    }];
}

@end

#endif /* defined(__FreeBSD__) */
