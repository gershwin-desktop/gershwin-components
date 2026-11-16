/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// FAT16 and FAT32 as two explicit formats: identifiers, the size rule, the
// per-OS mkfs argument vectors and the boot sector probe. All pure, so the
// BSD argument vectors are checked on any host.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DUFATFormat.h"
#import "DUStorageBackend.h"
#import "DUPartitionTableParser.h"
#import "DUMockStorageBackend.h"
#import "DUStorageDevice.h"
#import "DUStorageCapabilities.h"
#import "DUPartitionPlan.h"

#define MIB (1024ULL * 1024ULL)
#define GIB (1024ULL * MIB)

// Builds a 512 byte FAT boot sector with the BPB fields the probe reads.
static NSData *BootSector(unsigned spc, unsigned reserved, unsigned fats,
                          unsigned rootEntries, unsigned long total,
                          unsigned long fatSize16, unsigned long fatSize32)
{
    uint8_t b[512];
    memset(b, 0, sizeof b);
    b[11] = 0x00; b[12] = 0x02; // 512 bytes per sector
    b[13] = (uint8_t)spc;
    b[14] = reserved & 0xff; b[15] = (reserved >> 8) & 0xff;
    b[16] = (uint8_t)fats;
    b[17] = rootEntries & 0xff; b[18] = (rootEntries >> 8) & 0xff;
    if (total < 65536) {
        b[19] = total & 0xff; b[20] = (total >> 8) & 0xff;
    } else {
        b[32] = total & 0xff; b[33] = (total >> 8) & 0xff;
        b[34] = (total >> 16) & 0xff; b[35] = (total >> 24) & 0xff;
    }
    b[22] = fatSize16 & 0xff; b[23] = (fatSize16 >> 8) & 0xff;
    b[36] = fatSize32 & 0xff; b[37] = (fatSize32 >> 8) & 0xff;
    b[38] = (fatSize32 >> 16) & 0xff; b[39] = (fatSize32 >> 24) & 0xff;
    b[510] = 0x55; b[511] = 0xAA;
    return [NSData dataWithBytes:b length:512];
}

int main(void)
{
    @autoreleasepool {
        // vfat and its aliases are FAT32; fat16 stays; others untouched
        for (NSString *old in @[ @"vfat", @"fat", @"msdos", @"msdosfs",
                                 @"fat32", @"VFAT" ]) {
            PASS_EQUAL([DUFATFormat canonicalIdentifier:old], @"fat32",
                       "legacy identifier maps to fat32");
        }
        PASS_EQUAL([DUFATFormat canonicalIdentifier:@"fat16"], @"fat16",
                   "fat16 stays fat16");
        PASS_EQUAL([DUFATFormat canonicalIdentifier:@"ext4"], @"ext4",
                   "non-FAT identifier is untouched");
        PASS([DUFATFormat canonicalIdentifier:nil] == nil, "nil stays nil");
        PASS([DUFATFormat isFATIdentifier:@"vfat"] &&
             [DUFATFormat isFATIdentifier:@"fat16"] &&
             ![DUFATFormat isFATIdentifier:@"exfat"], "FAT family test");

        PASS_EQUAL([DUFATFormat displayNameForIdentifier:@"fat32"],
                   @"MS-DOS (FAT32)", "FAT32 display name");
        PASS_EQUAL([DUFATFormat displayNameForIdentifier:@"fat16"],
                   @"MS-DOS (FAT16)", "FAT16 display name");
        PASS_EQUAL([DUPartitionTableParser filesystemDisplayName:@"fat16"],
                   @"MS-DOS (FAT16)", "detected fat16 is shown by name");
        PASS_EQUAL([DUPartitionTableParser filesystemDisplayName:@"vfat"],
                   @"FAT", "an undifferentiated vfat is still FAT");

        // size rule
        PASS([DUFATFormat identifier:@"fat16" fitsBytes:2 * GIB],
             "FAT16 fits exactly 2 GiB");
        PASS(![DUFATFormat identifier:@"fat16" fitsBytes:2 * GIB + 1],
             "FAT16 does not fit above 2 GiB");
        PASS(![DUFATFormat identifier:@"fat16" fitsBytes:8 * MIB],
             "FAT16 does not fit below the tool minimum");
        PASS([DUFATFormat identifier:@"fat16" fitsBytes:16 * MIB],
             "FAT16 fits 16 MiB");
        PASS([DUFATFormat identifier:@"fat32" fitsBytes:2000ULL * GIB],
             "FAT32 has no practical upper bound");
        PASS(![DUFATFormat identifier:@"fat32" fitsBytes:16 * MIB],
             "FAT32 does not fit below 65525 clusters");
        PASS([DUFATFormat identifier:@"fat32" fitsBytes:64 * MIB],
             "FAT32 fits 64 MiB");
        PASS([DUFATFormat identifier:@"fat16" fitsBytes:0] &&
             [DUFATFormat identifier:@"fat32" fitsBytes:0],
             "unknown size never disables a format");
        PASS([DUFATFormat identifier:@"ext4" fitsBytes:1],
             "non-FAT formats have no FAT bounds");

        PASS([DUFATFormat sizeProblemForIdentifier:@"fat16" bytes:3 * GIB]
                 != nil, "refusal text for FAT16 above 2 GiB");
        PASS([DUFATFormat sizeProblemForIdentifier:@"fat16" bytes:GIB] == nil &&
             [DUFATFormat sizeProblemForIdentifier:@"vfat" bytes:GIB] == nil &&
             [DUFATFormat sizeProblemForIdentifier:@"ext4" bytes:1] == nil,
             "no refusal when it fits or is not FAT");

        // descriptors
        NSArray *descriptors = [DUFATFormat formatDescriptorsToolAvailable:YES];
        PASS(descriptors.count == 2, "two descriptors");
        NSDictionary *d32 = descriptors[0];
        NSDictionary *d16 = descriptors[1];
        PASS_EQUAL(d32[kDUFormatIdentifierKey], @"fat32", "FAT32 first");
        PASS_EQUAL(d16[kDUFormatIdentifierKey], @"fat16", "FAT16 second");
        PASS_EQUAL(d16[kDUFormatDisplayNameKey], @"MS-DOS (FAT16)",
                   "descriptor display name");
        PASS([d16[kDUFormatCanFormatKey] boolValue], "tool present: can format");
        PASS([d16[kDUFormatMaxBytesKey] unsignedLongLongValue] == 2 * GIB,
             "FAT16 descriptor carries 2 GiB");
        PASS(d32[kDUFormatMaxBytesKey] == nil, "FAT32 has no maximum");
        PASS(![[DUFATFormat formatDescriptorsToolAvailable:NO][0]
                  [kDUFormatCanFormatKey] boolValue],
             "tool missing: greyed out");
        PASS(![DUFATFormat descriptor:d16 allowsBytes:3 * GIB],
             "descriptor rejects 3 GiB for FAT16");
        PASS([DUFATFormat descriptor:d32 allowsBytes:3 * GIB],
             "descriptor accepts 3 GiB for FAT32");
        PASS([DUFATFormat descriptor:@{ kDUFormatIdentifierKey : @"ext4" }
                         allowsBytes:3 * GIB],
             "descriptor without bounds accepts anything");

        // Linux mkfs.fat
        PASS_EQUAL([DUFATFormat linuxMkfsArgumentsForIdentifier:@"fat32"
                                                          label:@"Backup disk 2"],
                   (@[ @"mkfs.vfat", @"-I", @"-F", @"32", @"-n", @"BACKUP DISK" ]),
                   "Linux FAT32 argv, label uppercased and cut to 11");
        PASS_EQUAL([DUFATFormat linuxMkfsArgumentsForIdentifier:@"fat16"
                                                          label:@"usb"],
                   (@[ @"mkfs.vfat", @"-I", @"-F", @"16", @"-n", @"USB" ]),
                   "Linux FAT16 argv");
        PASS_EQUAL([DUFATFormat linuxMkfsArgumentsForIdentifier:@"vfat"
                                                          label:nil],
                   (@[ @"mkfs.vfat", @"-I", @"-F", @"32" ]),
                   "Linux legacy vfat is FAT32, no label flag without label");

        // BSD newfs_msdos (FreeBSD, NextBSD, OpenBSD and NetBSD agree)
        PASS_EQUAL([DUFATFormat newfsMsdosArgumentsForIdentifier:@"fat32"
                                                           label:@"Data"],
                   (@[ @"-F", @"32", @"-L", @"DATA" ]), "newfs_msdos FAT32");
        PASS_EQUAL([DUFATFormat newfsMsdosArgumentsForIdentifier:@"fat16"
                                                           label:@""],
                   (@[ @"-F", @"16" ]), "newfs_msdos FAT16 without label");
        PASS_EQUAL([DUFATFormat newfsMsdosArgumentsForIdentifier:@"msdosfs"
                                                           label:@"x"],
                   (@[ @"-F", @"32", @"-L", @"X" ]),
                   "newfs_msdos legacy msdosfs is FAT32");
        PASS([DUFATFormat newfsMsdosArgumentsForIdentifier:@"ext4"
                                                     label:@"x"] == nil,
             "not a FAT format: no vector");

        // boot sector probe: 512 B sectors, 2 FATs
        PASS_EQUAL([DUFATFormat variantFromBootSector:
                       BootSector(4, 4, 2, 512, 100000, 100, 0)], @"fat16",
                   "16 bit FAT detected");
        PASS_EQUAL([DUFATFormat variantFromBootSector:
                       BootSector(1, 32, 2, 0, 200000, 0, 1600)], @"fat32",
                   "32 bit FAT detected");
        PASS_EQUAL([DUFATFormat variantFromBootSector:
                       BootSector(4, 1, 2, 224, 2880, 9, 0)], @"fat12",
                   "12 bit FAT detected");
        PASS([DUFATFormat variantFromBootSector:[NSData data]] == nil,
             "short data is not told");
        NSMutableData *noSig = [BootSector(4, 4, 2, 512, 100000, 100, 0) mutableCopy];
        ((uint8_t *)noSig.mutableBytes)[510] = 0;
        PASS([DUFATFormat variantFromBootSector:noSig] == nil,
             "no boot signature is not told");

        // a whole-disk erase plan is refused for FAT16 on a big disk, and
        // legacy vfat gets the FAT32 treatment (MBR)
        DUStorageDevice *big = [[DUStorageDevice alloc] initWithIdentifier:@"big"];
        big.capacityBytes = 8 * GIB;
        NSError *planError = nil;
        PASS([DUPartitionPlan planForWholeDiskErase:big filesystem:@"fat16"
                                               name:@"X" error:&planError] == nil &&
             planError != nil, "FAT16 whole-disk plan on 8 GiB is refused");
        planError = nil;
        DUPartitionPlan *okPlan = [DUPartitionPlan planForWholeDiskErase:big
                                  filesystem:@"vfat" name:@"X" error:&planError];
        PASS(okPlan != nil && [okPlan.scheme isEqualToString:@"mbr"],
             "vfat whole-disk plan is an MBR plan");

        // mock backend offers the two formats instead of vfat
        DUMockStorageBackend *mock = [[DUMockStorageBackend alloc] init];
        DUStorageDevice *dev = [[DUStorageDevice alloc] initWithIdentifier:@"x"];
        dev.capabilities = [DUStorageCapabilities capabilitiesWithAll:YES];
        NSMutableArray *ids = [NSMutableArray array];
        for (NSDictionary *f in [mock supportedFormatsForObject:dev]) {
            [ids addObject:f[kDUFormatIdentifierKey]];
        }
        PASS([ids containsObject:@"fat32"] && [ids containsObject:@"fat16"] &&
             ![ids containsObject:@"vfat"], "mock lists FAT32 and FAT16");
    }
    return 0;
}
