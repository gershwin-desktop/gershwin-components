/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionTypeNames.h"

static NSDictionary<NSNumber *, NSString *> *MBRTypeNames(void)
{
    static NSDictionary *names = nil;
    // Built on first use, like the other lookup tables in this directory.
    if (names == nil) {
        names = @{
            @0x01: @"FAT12",
            @0x04: @"FAT16 (small)",
            @0x05: @"Extended",
            @0x06: @"FAT16",
            @0x07: @"NTFS / exFAT",
            @0x0B: @"FAT32 (CHS)",
            @0x0C: @"FAT32 (LBA)",
            @0x0E: @"FAT16 (LBA)",
            @0x0F: @"Extended (LBA)",
            @0x82: @"Linux swap",
            @0x83: @"Linux",
            @0x85: @"Linux extended",
            @0x8E: @"Linux LVM",
            @0xA5: @"FreeBSD",
            @0xA6: @"OpenBSD",
            @0xA9: @"NetBSD",
            @0xAF: @"HFS / HFS+",
            @0xEE: @"GPT Protective",
            @0xEF: @"EFI System",
            @0xFD: @"Linux RAID",
        };
    }
    return names;
}

// Keys are lower-case. Names avoid vendor brands where a neutral one exists
// ("Basic Data", not the platform name some tools print).
static NSDictionary<NSString *, NSString *> *GPTTypeNames(void)
{
    static NSDictionary *names = nil;
    // Built on first use, like the other lookup tables in this directory.
    if (names == nil) {
        names = @{
            @"c12a7328-f81f-11d2-ba4b-00a0c93ec93b": @"EFI System",
            @"21686148-6449-6e6f-744e-656564454649": @"BIOS Boot",
            @"e3c9e316-0b5c-4db8-817d-f92df00215ae": @"Reserved",
            @"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7": @"Basic Data",
            @"de94bba4-06d1-4d40-a16a-bfd50179d6ac": @"Recovery",
            @"0fc63daf-8483-4772-8e79-3d69d8477de4": @"Linux filesystem",
            @"0657fd6d-a4ab-43c4-84e5-0933c84b4f4f": @"Linux swap",
            @"e6d6d379-f507-44c2-a23c-238f2a3df928": @"Linux LVM",
            @"a19d880f-05fc-4d3b-a006-743f0f84911e": @"Linux RAID",
            @"933ac7e1-2eb4-4f13-b844-0e14e2aef915": @"Linux home",
            @"4f68bce3-e8cd-4db1-96e7-fbcaf984b709": @"Linux root (x86-64)",
            @"bc13c2ff-59e6-4262-a352-b275fd6f7172": @"Linux extended boot",
            @"516e7cb4-6ecf-11d6-8ff8-00022d09712b": @"FreeBSD Data",
            @"83bd6b9d-7f41-11dc-be0b-001560b84f0f": @"FreeBSD Boot",
            @"516e7cb5-6ecf-11d6-8ff8-00022d09712b": @"FreeBSD swap",
            @"516e7cb6-6ecf-11d6-8ff8-00022d09712b": @"FreeBSD UFS",
            @"516e7cb8-6ecf-11d6-8ff8-00022d09712b": @"FreeBSD Vinum",
            @"516e7cba-6ecf-11d6-8ff8-00022d09712b": @"FreeBSD ZFS",
            @"49f48d32-b10e-11dc-b99b-0019d1879648": @"NetBSD swap",
            @"49f48d5a-b10e-11dc-b99b-0019d1879648": @"NetBSD FFS",
            @"824cc7a0-36a8-11e3-890a-952519ad3f61": @"OpenBSD Data",
            @"48465300-0000-11aa-aa11-00306543ecac": @"HFS+",
            @"7c3457ef-0000-11aa-aa11-00306543ecac": @"APFS",
        };
    }
    return names;
}

static BOOL LooksLikeGUID(NSString *s)
{
    if (s.length != 36) {
        return NO;
    }
    for (NSUInteger i = 0; i < 36; i++) {
        unichar c = [s characterAtIndex:i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') {
                return NO;
            }
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                     (c >= 'A' && c <= 'F'))) {
            return NO;
        }
    }
    return YES;
}

static NSString *Trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@implementation DUPartitionTypeNames

+ (NSString *)schemeDisplayName:(NSString *)schemeToken
{
    NSString *token = [Trimmed(schemeToken ?: @"") lowercaseString];
    if (token.length == 0) {
        return NSLocalizedString(@"None", nil);
    }
    if ([token isEqual:@"gpt"] || [token containsString:@"guid"]) {
        return NSLocalizedString(@"GUID Partition Map", nil);
    }
    if ([token isEqual:@"mbr"] || [token isEqual:@"dos"] ||
        [token isEqual:@"msdos"]) {
        return NSLocalizedString(@"Master Boot Record", nil);
    }
    if ([token isEqual:@"mac"] || [token isEqual:@"apm"]) {
        return NSLocalizedString(@"Apple Partition Map", nil);
    }
    if ([token isEqual:@"bsd"] || [token containsString:@"disklabel"]) {
        return NSLocalizedString(@"BSD Disklabel", nil);
    }
    // Unknown scheme: show what the OS reported rather than rename it.
    return Trimmed(schemeToken);
}

+ (NSString *)typeDisplayForCode:(NSString *)code
{
    NSString *trimmed = Trimmed(code ?: @"");
    if (trimmed.length == 0) {
        return nil;
    }
    NSString *name = nil;
    NSString *shown = trimmed;
    if ([trimmed hasPrefix:@"0x"] || [trimmed hasPrefix:@"0X"]) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:
            [trimmed substringFromIndex:2]];
        if ([scanner scanHexInt:&value] && value <= 0xFF) {
            shown = [NSString stringWithFormat:@"0x%02X", value];
            name = MBRTypeNames()[@(value)];
        }
    } else if (LooksLikeGUID(trimmed)) {
        shown = [trimmed uppercaseString];
        name = GPTTypeNames()[[trimmed lowercaseString]];
    }
    return name != nil
        ? [NSString stringWithFormat:@"%@, %@", shown, name] : shown;
}

+ (NSString *)typeCodeFromLsblkPartType:(NSString *)raw
{
    NSString *trimmed = Trimmed(raw ?: @"");
    if (trimmed.length == 0) {
        return nil;
    }
    if ([trimmed hasPrefix:@"0x"] || [trimmed hasPrefix:@"0X"]) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:
            [trimmed substringFromIndex:2]];
        if ([scanner scanHexInt:&value]) {
            return [NSString stringWithFormat:@"0x%02X", value];
        }
    }
    return LooksLikeGUID(trimmed) ? [trimmed lowercaseString] : trimmed;
}

+ (NSString *)typeCodeFromGeomRawType:(NSString *)rawType
                                 type:(NSString *)typeToken
{
    NSString *raw = Trimmed(rawType ?: @"");
    if (raw.length > 0) {
        NSScanner *scanner = [NSScanner scannerWithString:raw];
        NSInteger value = 0;
        // gpart prints an MBR type byte in decimal, unlike lsblk's hex.
        if ([scanner scanInteger:&value] && scanner.isAtEnd && value >= 0 &&
            value <= 0xFF) {
            return [NSString stringWithFormat:@"0x%02X", (unsigned)value];
        }
        return LooksLikeGUID(raw) ? [raw lowercaseString] : raw;
    }
    NSString *token = Trimmed(typeToken ?: @"");
    return token.length > 0 ? token : nil;
}

@end
