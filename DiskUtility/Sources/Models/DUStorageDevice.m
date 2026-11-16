/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageDevice.h"

#import "DUProcessRunner.h"

@implementation DUStorageDevice

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

// The type is fixed by the class; refuse mismatches instead of guessing.
- (instancetype)initWithType:(DUStorageObjectType)type
                   identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeDevice);
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

// Best-effort SMART self-assessment for a block device. Relies on
// smartmontools' smartctl, which may be absent or require privileges; any
// failure degrades to "Not Supported" rather than fabricating a result.
//
// Run through DUProcessRunner, never a bare NSTask: this is called from the
// discovery poll every few seconds, and a bare waitUntilExit with no timeout
// means one unresponsive USB-SATA bridge (a well-known smartctl hang) wedges
// discovery for good, so the app would never notice any disk change again.
+ (DUStorageSmartStatus)querySmartStatusForPath:(NSString *)devicePath
{
    if (devicePath.length == 0) {
        return DUStorageSmartStatusNotSupported;
    }
    NSString *smartctl = [DUProcessRunner executablePathForName:@"smartctl"];
    if (smartctl == nil) {
        return DUStorageSmartStatusNotSupported;
    }

    NSError *runError = nil;
    DUProcessResult *result = [DUProcessRunner
        runExecutable:smartctl
           arguments:@[ @"-H", devicePath ]
               error:&runError];
    if (result == nil || result.timedOut) {
        return DUStorageSmartStatusNotSupported;
    }

    /* smartctl(8) returns a BITMASK, not an equality code:
     *   bit 1 (1)  command line parse error
     *   bit 2 (2)  device open failed / insufficient permission
     *   bit 3 (4)  some SMART command to the disk failed
     *   bit 4 (8)  SMART status returned "DISK FAILING"
     *   bit 5 (16) prefail attributes are at or past their threshold
     * The old `status == 4` test mapped "the SMART command did not answer"
     * onto FAILING - so a healthy drive behind a bridge without ATA SMART
     * pass-through was announced as failing, which is the most alarming
     * field in the panel a user reads before erasing a disk - and never
     * looked at bits 8 or 16, so a genuinely dying drive could slip
     * through as "Not Supported". */
    int status = result.terminationStatus;
    if ((status & 8) != 0 || (status & 16) != 0) {
        return DUStorageSmartStatusFailing;
    }
    if ((status & 2) != 0 || (status & 4) != 0) {
        return DUStorageSmartStatusNotSupported;
    }
    if (!result.exitedNormally || status != 0) {
        return DUStorageSmartStatusUnknown;
    }

    NSString *transcript =
        [NSString stringWithFormat:@"%@ %@", result.standardOutput,
                                   result.standardError];
    NSString *upper = transcript.uppercaseString;
    if ([upper containsString:@"FAILED"] ||
        [upper containsString:@"FAILURE"]) {
        return DUStorageSmartStatusFailing;
    }
    if ([upper containsString:@"PASSED"] || [upper containsString:@"OK"]) {
        return DUStorageSmartStatusVerified;
    }
    return DUStorageSmartStatusNotSupported;
}

+ (NSString *)localizedSmartStatus:(DUStorageSmartStatus)status
{
    switch (status) {
        case DUStorageSmartStatusVerified:
            return NSLocalizedString(@"Verified", nil);
        case DUStorageSmartStatusFailing:
            return NSLocalizedString(@"Failing", nil);
        case DUStorageSmartStatusNotSupported:
            return NSLocalizedString(@"Not Supported", nil);
        case DUStorageSmartStatusUnknown:
        default:
            return NSLocalizedString(@"Unknown", nil);
    }
}

// The one health verdict the app actually has is the SMART self-assessment.
// healthStatus is the user-facing row of the Information panel, and it used
// to be filled only by the mock backend, so every real disk on every platform
// displayed "Health Status: -" next to a populated SMART row.
+ (NSString *)healthStatusForSmartStatus:(DUStorageSmartStatus)status
{
    switch (status) {
        case DUStorageSmartStatusVerified:
            return NSLocalizedString(@"Healthy", nil);
        case DUStorageSmartStatusFailing:
            return NSLocalizedString(@"Failing", nil);
        case DUStorageSmartStatusUnknown:
            return NSLocalizedString(@"Unknown", nil);
        case DUStorageSmartStatusNotSupported:
        default:
            // No verdict is not the same as a bad one; leave the row blank
            // rather than inventing a health claim.
            return nil;
    }
}

@end
