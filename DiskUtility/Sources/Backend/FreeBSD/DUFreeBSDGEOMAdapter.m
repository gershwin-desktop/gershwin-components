/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#if defined(__FreeBSD__)

#import "DUFreeBSDGEOMAdapter.h"

#import "DUErrors.h"
#import "DUFreeBSDDeviceDiscovery.h"
#import "DUFreeBSDGEOMParser.h"
#import "DUParsing.h"
#import "DUProcessRunner.h"

#import <sys/wait.h>

NSString *const DUFreeBSDBackendDetailKey = @"DUBackendDetail";

// Geom prints sizes as "<bytes> (<human>)"; only the leading integer is
// authoritative, the parenthesized part is display rounding.
@implementation DUFreeBSDGEOMAdapter

+ (unsigned long long)bytesFromGeomSizeToken:(NSString *)token
{
    if (token.length == 0) {
        return 0;
    }
    // strtoull instead of NSScanner: GNUstep lacks an unsigned long long
    // scanning API on all supported versions.
    return strtoull(token.UTF8String, NULL, 10);
}

+ (NSArray<NSDictionary<NSString *, id> *> *)listClass:(NSString *)className
                                                 name:(NSString *)providerName
                                                error:(NSError **)error
{
    NSString *geom = [DUFreeBSDToolCache pathForTool:@"geom"];
    if (geom == nil) {
        if (error != NULL) {
            *error = DUErrorMake(DUErrorUnsupportedOperation,
                                 NSLocalizedString(
                                     @"The required tool geom is not "
                                     @"installed.",
                                     nil));
        }
        return nil;
    }

    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObject:className];
    [arguments addObject:@"list"];
    if (providerName.length > 0) {
        [arguments addObject:providerName];
    }

    NSError *runError = nil;
    DUProcessResult *result = [DUProcessRunner runExecutable:geom
                                                   arguments:arguments
                                                       error:&runError];
    if (result == nil) {
        if (error != NULL) {
            *error = runError ?: DUErrorMake(DUErrorDiscoveryFailed,
                                             NSLocalizedString(
                                                 @"geom could not be run.",
                                                 nil));
        }
        return nil;
    }
    if (!result.exitedNormally ||
        ![result exitedWithStatus:0]) {
        if (result.standardOutput.length == 0) {
            NSString *diagnostic =
                [DUParsing trimmedString:result.standardError];
            /* geom(8) says "Class 'PART' does not have an instance named
             * 'da1'" and exits 1 both for a disk that genuinely has no
             * partition table and for a provider that does not exist at all.
             * The first is a real answer ("unpartitioned"), so it is reported
             * as an empty table; anything else is a failure to read, and the
             * caller must not confuse it with an empty disk. */
            BOOL providerAbsent =
                [diagnostic rangeOfString:@"does not have an instance named"]
                        .location != NSNotFound;
            if (providerAbsent) {
                return @[];
            }
            if (error != NULL) {
                *error = [NSError errorWithDomain:DUStorageErrorDomain
                                             code:DUErrorDiscoveryFailed
                                         userInfo:@{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"Reading the storage layout "
                                          @"failed.",
                                          nil),
                    DUFreeBSDBackendDetailKey : diagnostic ?: @"",
                }];
            }
            return nil;
        }
    }
    return [DUFreeBSDGEOMParser parseListOutput:result.standardOutput];
}

+ (NSDictionary<NSString *, NSDictionary *> *)mountedVolumesFromOutput:
        (NSString *)output
{
    NSMutableDictionary<NSString *, NSDictionary *> *table =
        [NSMutableDictionary dictionary];
    for (NSString *rawLine in
             [output componentsSeparatedByCharactersInSet:
                         [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [DUParsing trimmedString:rawLine];
        NSRange separator = [line rangeOfString:@" on "];
        if (separator.location == NSNotFound || separator.location == 0) {
            continue;
        }
        NSString *device =
            [DUParsing trimmedString:
                           [line substringToIndex:separator.location]];
        NSString *rest = [line substringFromIndex:
                                   NSMaxRange(separator)];
        NSRange parens = [rest rangeOfString:@" ("];
        if (parens.location == NSNotFound) {
            continue;
        }
        NSString *mountPoint = [DUParsing trimmedString:
            [rest substringToIndex:parens.location]];
        NSString *options =
            [rest substringFromIndex:NSMaxRange(parens)];
        // Options look like "(ufs, local, journaled soft-updates)".
        NSRange close = [options rangeOfString:@")"];
        NSString *inner = close.location == NSNotFound
            ? options
            : [options substringToIndex:close.location];
        NSArray<NSString *> *fields =
            [inner componentsSeparatedByString:@","];
        NSString *fstype =
            fields.count > 0
                ? [DUParsing trimmedString:fields.firstObject]
                : @"";
        if (device.length == 0 || mountPoint.length == 0 ||
            fstype.length == 0) {
            continue;
        }
        table[device] =
            @{ @"mountPoint" : mountPoint, @"fstype" : fstype };
    }
    return table;
}

+ (NSDictionary<NSString *, NSDictionary *> *)currentMountTable
{
    NSString *mount = [DUFreeBSDToolCache pathForTool:@"mount"];
    if (mount == nil) {
        return @{};
    }
    DUProcessResult *result =
        [DUProcessRunner runExecutable:mount arguments:@[] error:NULL];
    if (result == nil || result.standardOutput.length == 0) {
        return @{};
    }
    return [self mountedVolumesFromOutput:result.standardOutput];
}

+ (NSString *)filesystemTokenForPartitionType:(NSString *)rawType
{
    NSString *type =
        [DUParsing trimmedString:rawType].lowercaseString;
    if (type.length == 0) {
        return nil;
    }

    /* GPT type names gpart reports verbatim. Built per call: the table is
     * tiny and no GCD primitives may be used for lazy initialization.
     *
     * An EFI system partition holds a FAT filesystem but is never mounted and
     * must not be erased as a data volume, so it maps to a distinct token
     * rather than to "msdosfs". FreeBSD also has no ext4 mounter, so
     * "linux-data" is left unmapped: reporting ext4 there made the app offer
     * Mount on a Linux partition and then fail with an opaque mount(8)
     * error. */
    NSDictionary<NSString *, NSString *> *gptTable = @{
        @"freebsd-ufs" : @"ufs",
        @"ufs" : @"ufs",
        @"freebsd-swap" : @"swap",
        @"linux-swap" : @"swap",
        @"fat16" : @"msdosfs",
        @"fat32" : @"msdosfs",
        @"fat" : @"msdosfs",
        @"efi" : @"efi",
        @"ms-basic-data" : @"msdosfs",
        @"basic-data" : @"msdosfs",
    };
    NSString *mapped = gptTable[type];
    if (mapped != nil) {
        return mapped;
    }

    // MBR partitions print as "!<decimal id>"; FAT family ids are the ones
    // we can name without probing the boot sector.
    if ([type hasPrefix:@"!"]) {
        NSString *identifier =
            [DUParsing trimmedString:[type substringFromIndex:1]];
        NSArray<NSString *> *fatIds =
            @[ @"1", @"4", @"6", @"11", @"12", @"14" ];
        return [fatIds containsObject:identifier] ? @"msdosfs" : nil;
    }
    return nil;
}

@end

#endif /* defined(__FreeBSD__) */
