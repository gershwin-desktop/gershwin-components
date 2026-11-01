/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUFATFormat.h"
#import "DUStorageBackend.h"

static const unsigned long long kMiB = 1024ULL * 1024ULL;
static const unsigned long long kFAT16Max = 2048ULL * kMiB;
// Measured with mkfs.fat: below about 10 MiB it refuses -F 16.
static const unsigned long long kFAT16Min = 10ULL * kMiB;
// A volume with fewer than 65525 clusters is FAT16 by definition, so FAT32
// needs a little over 32 MiB.
static const unsigned long long kFAT32Min = 33ULL * kMiB;
static const NSUInteger kLabelLimit = 11;

@implementation DUFATFormat

+ (NSString *)canonicalIdentifier:(NSString *)identifier
{
    NSString *key = identifier.lowercaseString;
    if ([key isEqualToString:@"fat16"]) {
        return @"fat16";
    }
    if ([@[ @"fat32", @"vfat", @"fat", @"msdos", @"msdosfs" ]
            containsObject:key]) {
        return @"fat32";
    }
    return identifier;
}

+ (BOOL)isFATIdentifier:(NSString *)identifier
{
    NSString *canonical = [self canonicalIdentifier:identifier];
    return [canonical isEqualToString:@"fat32"] ||
        [canonical isEqualToString:@"fat16"];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier
{
    NSString *canonical = [self canonicalIdentifier:identifier];
    if ([canonical isEqualToString:@"fat16"]) {
        return NSLocalizedString(@"MS-DOS (FAT16)", nil);
    }
    if ([canonical isEqualToString:@"fat32"]) {
        return NSLocalizedString(@"MS-DOS (FAT32)", nil);
    }
    return nil;
}

+ (unsigned long long)minimumBytesForIdentifier:(NSString *)identifier
{
    NSString *canonical = [self canonicalIdentifier:identifier];
    if ([canonical isEqualToString:@"fat16"]) {
        return kFAT16Min;
    }
    return [canonical isEqualToString:@"fat32"] ? kFAT32Min : 0;
}

+ (unsigned long long)maximumBytesForIdentifier:(NSString *)identifier
{
    return [[self canonicalIdentifier:identifier] isEqualToString:@"fat16"]
        ? kFAT16Max : 0;
}

+ (BOOL)identifier:(NSString *)identifier fitsBytes:(unsigned long long)bytes
{
    if (bytes == 0) {
        return YES;
    }
    unsigned long long min = [self minimumBytesForIdentifier:identifier];
    unsigned long long max = [self maximumBytesForIdentifier:identifier];
    return bytes >= min && (max == 0 || bytes <= max);
}

+ (NSString *)sizeProblemForIdentifier:(NSString *)identifier
                                 bytes:(unsigned long long)bytes
{
    if (![self isFATIdentifier:identifier] ||
        [self identifier:identifier fitsBytes:bytes]) {
        return nil;
    }
    NSString *name = [self displayNameForIdentifier:identifier];
    if (bytes < [self minimumBytesForIdentifier:identifier]) {
        return [NSString stringWithFormat:
                NSLocalizedString(@"%@ needs at least %llu MB.", nil),
                name, [self minimumBytesForIdentifier:identifier] / kMiB];
    }
    return [NSString stringWithFormat:
            NSLocalizedString(@"%@ can hold at most %llu MB; choose "
                              @"MS-DOS (FAT32) for a larger volume.", nil),
            name, [self maximumBytesForIdentifier:identifier] / kMiB];
}

+ (NSArray<NSDictionary *> *)formatDescriptorsToolAvailable:(BOOL)available
{
    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
    for (NSString *identifier in @[ @"fat32", @"fat16" ]) {
        NSMutableDictionary *descriptor = [@{
            kDUFormatIdentifierKey : identifier,
            kDUFormatDisplayNameKey :
                [self displayNameForIdentifier:identifier],
            kDUFormatCanFormatKey : @(available),
        } mutableCopy];
        unsigned long long min = [self minimumBytesForIdentifier:identifier];
        unsigned long long max = [self maximumBytesForIdentifier:identifier];
        if (min > 0) {
            descriptor[kDUFormatMinBytesKey] = @(min);
        }
        if (max > 0) {
            descriptor[kDUFormatMaxBytesKey] = @(max);
        }
        [descriptors addObject:descriptor];
    }
    return descriptors;
}

+ (BOOL)descriptor:(NSDictionary *)descriptor allowsBytes:(unsigned long long)bytes
{
    if (bytes == 0) {
        return YES;
    }
    unsigned long long min =
        [descriptor[kDUFormatMinBytesKey] unsignedLongLongValue];
    unsigned long long max =
        [descriptor[kDUFormatMaxBytesKey] unsignedLongLongValue];
    return bytes >= min && (max == 0 || bytes <= max);
}

// Volume labels of both families are upper case and at most 11 characters;
// the tools reject or mangle anything else.
+ (NSString *)fittedLabel:(NSString *)label
{
    NSString *fitted = label.uppercaseString;
    if (fitted.length > kLabelLimit) {
        fitted = [fitted substringToIndex:kLabelLimit];
    }
    return fitted;
}

+ (NSString *)fatTypeArgument:(NSString *)identifier
{
    NSString *canonical = [self canonicalIdentifier:identifier];
    if ([canonical isEqualToString:@"fat16"]) {
        return @"16";
    }
    return [canonical isEqualToString:@"fat32"] ? @"32" : nil;
}

+ (NSArray<NSString *> *)linuxMkfsArgumentsForIdentifier:(NSString *)identifier
                                                   label:(NSString *)label
{
    NSString *type = [self fatTypeArgument:identifier];
    if (type == nil) {
        return nil;
    }
    // -I because the target is a whole disk, which mkfs.fat otherwise refuses.
    NSMutableArray<NSString *> *arguments =
        [@[ @"mkfs.vfat", @"-I", @"-F", type ] mutableCopy];
    if (label.length > 0) {
        [arguments addObjectsFromArray:@[ @"-n", [self fittedLabel:label] ]];
    }
    return arguments;
}

+ (NSArray<NSString *> *)newfsMsdosArgumentsForIdentifier:(NSString *)identifier
                                                    label:(NSString *)label
{
    NSString *type = [self fatTypeArgument:identifier];
    if (type == nil) {
        return nil;
    }
    NSMutableArray<NSString *> *arguments =
        [@[ @"-F", type ] mutableCopy];
    if (label.length > 0) {
        [arguments addObjectsFromArray:@[ @"-L", [self fittedLabel:label] ]];
    }
    return arguments;
}

static unsigned ReadLE(const uint8_t *bytes, NSUInteger offset, NSUInteger width)
{
    unsigned value = 0;
    for (NSUInteger i = 0; i < width; i++) {
        value |= (unsigned)bytes[offset + i] << (8 * i);
    }
    return value;
}

+ (NSString *)variantFromBootSector:(NSData *)sector
{
    if (sector.length < 512) {
        return nil;
    }
    const uint8_t *b = sector.bytes;
    if (b[510] != 0x55 || b[511] != 0xAA) {
        return nil;
    }
    unsigned bytesPerSector = ReadLE(b, 11, 2);
    unsigned perCluster = b[13];
    unsigned reserved = ReadLE(b, 14, 2);
    unsigned fats = b[16];
    unsigned rootEntries = ReadLE(b, 17, 2);
    unsigned long total = ReadLE(b, 19, 2) ?: ReadLE(b, 32, 4);
    unsigned long fatSize = ReadLE(b, 22, 2) ?: ReadLE(b, 36, 4);
    if (bytesPerSector < 512 || (bytesPerSector & (bytesPerSector - 1)) != 0 ||
        perCluster == 0 || fats == 0 || total == 0 || fatSize == 0) {
        return nil;
    }
    unsigned long rootSectors =
        ((unsigned long)rootEntries * 32 + bytesPerSector - 1) / bytesPerSector;
    unsigned long overhead = reserved + (unsigned long)fats * fatSize + rootSectors;
    if (total <= overhead) {
        return nil;
    }
    unsigned long clusters = (total - overhead) / perCluster;
    if (clusters < 4085) {
        return @"fat12";
    }
    return clusters < 65525 ? @"fat16" : @"fat32";
}

@end
