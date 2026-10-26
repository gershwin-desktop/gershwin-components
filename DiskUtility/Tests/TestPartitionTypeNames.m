/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The names shown for a disk's partition map scheme and for a
 * partition's table-level type, shared by every backend. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "TestFixtures.h"
#import "DUPartitionTypeNames.h"
#import "DUFreeBSDGEOMParser.h"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("Scheme names")
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"gpt"],
                   @"GUID Partition Map", "gpt");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"mbr"],
                   @"Master Boot Record", "mbr");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"dos"],
                   @"Master Boot Record", "lsblk calls MBR dos");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"mac"],
                   @"Apple Partition Map", "lsblk calls APM mac");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"APM"],
                   @"Apple Partition Map", "gpart calls it APM");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"bsd"],
                   @"BSD Disklabel", "bsd");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:nil],
                   @"None", "no table");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@""],
                   @"None", "empty token means no table");
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:@"sun"],
                   @"sun", "an unknown scheme is shown as reported");
    END_SET("Scheme names")

    START_SET("MBR type names")
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:@"0x0C"],
                   @"0x0C, FAT32 (LBA)", "FAT32 LBA");
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:@"0xc"],
                   @"0x0C, FAT32 (LBA)", "lsblk spells the byte 0xc");
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:@"0x83"],
                   @"0x83, Linux", "Linux");
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:@"0xEE"],
                   @"0xEE, GPT Protective", "protective");
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:@"0x7F"],
                   @"0x7F", "unknown byte keeps only its code");
    END_SET("MBR type names")

    START_SET("GPT type names")
        PASS_EQUAL([DUPartitionTypeNames
                       typeDisplayForCode:
                           @"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"],
                   @"C12A7328-F81F-11D2-BA4B-00A0C93EC93B, EFI System",
                   "EFI System");
        PASS_EQUAL([DUPartitionTypeNames
                       typeDisplayForCode:
                           @"0FC63DAF-8483-4772-8E79-3D69D8477DE4"],
                   @"0FC63DAF-8483-4772-8E79-3D69D8477DE4, Linux filesystem",
                   "Linux filesystem, upper case input");
        PASS([[DUPartitionTypeNames
                  typeDisplayForCode:
                      @"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"]
                 hasSuffix:@", Basic Data"],
             "basic data without a platform brand");
        PASS([[DUPartitionTypeNames
                  typeDisplayForCode:
                      @"516e7cb6-6ecf-11d6-8ff8-00022d09712b"]
                 hasSuffix:@", FreeBSD UFS"], "FreeBSD UFS");
        PASS_EQUAL([DUPartitionTypeNames
                       typeDisplayForCode:
                           @"11111111-2222-3333-4444-555555555555"],
                   @"11111111-2222-3333-4444-555555555555",
                   "unknown GUID keeps only its code");
    END_SET("GPT type names")

    START_SET("Codes from lsblk and gpart")
        PASS_EQUAL([DUPartitionTypeNames typeCodeFromLsblkPartType:@"0xc"],
                   @"0x0C", "byte padded and upper-cased");
        PASS_EQUAL([DUPartitionTypeNames
                       typeCodeFromLsblkPartType:
                           @"C12A7328-F81F-11D2-BA4B-00A0C93EC93B"],
                   @"c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
                   "GUID lower-cased");
        PASS([DUPartitionTypeNames typeCodeFromLsblkPartType:@""] == nil,
             "no type, no code");
        PASS_EQUAL([DUPartitionTypeNames typeCodeFromGeomRawType:@"12"
                                                            type:@"fat32lba"],
                   @"0x0C", "gpart prints the MBR byte in decimal");
        PASS_EQUAL([DUPartitionTypeNames
                       typeCodeFromGeomRawType:
                           @"516e7cb6-6ecf-11d6-8ff8-00022d09712b"
                                          type:@"freebsd-ufs"],
                   @"516e7cb6-6ecf-11d6-8ff8-00022d09712b", "GPT GUID");
        PASS_EQUAL([DUPartitionTypeNames typeCodeFromGeomRawType:nil
                                                            type:@"freebsd-ufs"],
                   @"freebsd-ufs", "BSD labels carry only the type token");
    END_SET("Codes from lsblk and gpart")

    START_SET("gpart MBR fixture")
        /* Hand-written in the layout of gpart/geom output for an MBR
         * disk with a FAT32 LBA slice (rawtype is decimal there). */
        NSArray *providers = [DUFreeBSDGEOMParser parseListOutput:
            TestFixtureNamed(@"FreeBSD/geom-part-list-da0-mbr.txt")];
        PASS(providers.count == 1, "one slice");
        NSDictionary *slice = providers.firstObject;
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:slice[@"scheme"]],
                   @"Master Boot Record", "scheme from the geom header");
        NSString *code = [DUPartitionTypeNames
            typeCodeFromGeomRawType:slice[@"rawtype"] type:slice[@"type"]];
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:code],
                   @"0x0C, FAT32 (LBA)", "slice type");
    END_SET("gpart MBR fixture")

    START_SET("gpart GPT fixture")
        NSArray *providers = [DUFreeBSDGEOMParser parseListOutput:
            TestFixtureNamed(@"FreeBSD/geom-part-list-ada0.txt")];
        NSDictionary *esp = providers[0];
        PASS_EQUAL([DUPartitionTypeNames schemeDisplayName:esp[@"scheme"]],
                   @"GUID Partition Map", "GPT");
        NSString *code = [DUPartitionTypeNames
            typeCodeFromGeomRawType:esp[@"rawtype"] type:esp[@"type"]];
        PASS_EQUAL([DUPartitionTypeNames typeDisplayForCode:code],
                   @"C12A7328-F81F-11D2-BA4B-00A0C93EC93B, EFI System",
                   "ESP type");
    END_SET("gpart GPT fixture")

    [arp release];
    return 0;
}
