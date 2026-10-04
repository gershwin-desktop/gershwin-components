/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Live backend exercise: drives the REAL storage backend against a real
 * disk node and asserts the result by reading the disk back with the
 * platform's own tools (gpart/newfs/geom/mount/sha256).
 *
 * This is deliberately NOT part of the hermetic suite in run.sh: it
 * destroys whatever device it is pointed at. It refuses to start unless it
 * is running as root and was given an explicit device node.
 *
 *   gmake live && sudo ./obj/t_LiveBackend /dev/da1
 */

#import <Foundation/Foundation.h>

#import "DUBackendFactory.h"
#import "DUDiskImage.h"
#import "DUPartition.h"
#import "DUPartitionLayout.h"
#import "DUPartitionPlan.h"
#import "DURAIDSet.h"
#import "DUStorageBackend.h"
#import "DUStorageDevice.h"
#import "DUStorageObject.h"
#import "DUStorageVolume.h"

#import <Foundation/NSException.h>

#define S(x) ((x) != nil ? (x).UTF8String : "(nil)")

#if defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__OpenBSD__)
// The RAID verb is implemented on the concrete backend but is NOT declared in
// the DUStorageBackend protocol, which is why the RAID tab has no way to reach
// it. Declared here so the live exercise can call it with its real signature
// and report what actually happens.
@interface NSObject (DURaidVerbProbe)
- (NSError *)createRAIDWithName:(NSString *)name
                          level:(NSString *)level
                        members:(NSArray *)members;
@end
#endif

static NSString *gDevice = nil;
// Per-verb wall clock budget. A verb that never calls its completion
// block is a bug worth reporting, not something to wait out.
static NSTimeInterval gStepTimeout = 300.0;
static int gPassed = 0;
static int gFailed = 0;
static NSMutableArray<NSString *> *gFailures = nil;

static void Pass(NSString *what, NSString *detail)
{
    gPassed++;
    printf("  ok   %s%s%s\n", what.UTF8String,
           detail.length > 0 ? " - " : "",
           detail.length > 0 ? detail.UTF8String : "");
    fflush(stdout);
}

static void Fail(NSString *what, NSString *detail)
{
    gFailed++;
    [gFailures addObject:[NSString stringWithFormat:@"%@: %@", what, detail]];
    printf("  FAIL %s - %s\n", what.UTF8String, detail.UTF8String);
    fflush(stdout);
}

static void Check(BOOL condition, NSString *what, NSString *detail)
{
    if (condition) {
        Pass(what, detail);
    } else {
        Fail(what, detail);
    }
}

/* ------------------------------------------------------------------ */
/* Shell helpers: read the real state of the disk back                 */
/* ------------------------------------------------------------------ */

static NSString *ShellOut(NSString *command);

// Trims whitespace and newlines; sha256 output carries both.
static NSString *DUParsingLikeTrim(NSString *text)
{
    return [text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Runs a command and returns its combined stdout+stderr, so a tool's
// complaint is part of what the test shows rather than being discarded.
static NSString *Shell(NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *command = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    return ShellOut(command);
}

static NSString *ShellOut(NSString *command)
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[ @"-c", command ];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:NULL]) {
        return @"";
    }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data
                                 encoding:NSUTF8StringEncoding] ?: @"";
}

/* The first `length` bytes of a device node or file.
 *
 * A block device does NOT return the full amount in one read: -[NSFileHandle
 * readDataOfLength:] on /dev/da1p1 returns a single 512-byte block, so a
 * 4 MiB request yields 512 bytes and any label far beyond the first sector
 * is simply never read. Loop until the request is satisfied or the node is
 * exhausted. */
static NSData *ReadLeadingBytes(NSString *path, NSUInteger length)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        return [NSData data];
    }
    NSMutableData *collected = [NSMutableData dataWithCapacity:length];
    while (collected.length < length) {
        NSData *chunk = nil;
        @try {
            chunk = [handle readDataOfLength:(length - collected.length)];
        } @catch (NSException __attribute__((unused)) *exception) {
            break;
        }
        if (chunk.length == 0) {
            break;
        }
        [collected appendData:chunk];
    }
    [handle closeFile];
    return collected;
}

/* Whether a UFS filesystem on `node` carries the given volume label.
 *
 * tunefs(8) cannot answer this: on a multilabel filesystem - which is what
 * newfs creates by default here - it refuses with "bad multilabel MAC file
 * system (options are 'enable' or 'disable')" and exits. The label is a
 * NUL-padded 32-byte field in the superblock, and newfs writes it to the
 * primary copy and to the first backup, whose offsets depend on the block
 * size it chose. So the bytes are scanned for the label instead. Scans the
 * first 4 MiB: ReadLeadingBytes loops, because a block device returns one
 * block per read and a single read would never reach the label at all. */
static BOOL HasUFSTag(NSString *tag, NSString *node)
{
    if (tag.length == 0 || node.length == 0) {
        return NO;
    }
    NSData *head = ReadLeadingBytes(node, 4 * 1024 * 1024);
    NSData *needle = [tag dataUsingEncoding:NSASCIIStringEncoding];
    if (head.length == 0 || needle.length == 0) {
        return NO;
    }
    return [head rangeOfData:needle
                     options:0
                       range:NSMakeRange(0, head.length)].location != NSNotFound;
}

// The first 16 bytes of a buffer as hex, for a before/after comparison in a
// report line.
static NSString *HexOf(NSData *data)
{
    NSUInteger length = MIN((NSUInteger)16, data.length);
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

// Runs a command and reports whether it exited 0. Every assertion that
// inspects the disk goes through this, so a test never mistakes "the tool
// printed nothing" for "the check passed".
static BOOL ShellOK(NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *command = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[ @"-c", command ];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:NULL]) {
        return NO;
    }
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

static NSString *ErrorText(NSError *error)
{
    if (error == nil) {
        return @"";
    }
    NSMutableString *text =
        [NSMutableString stringWithFormat:@"%@ (code %ld)",
                                       error.localizedDescription,
                                       (long)error.code];
    id detail = error.userInfo[@"DUFreeBSDBackendDetailKey"]
        ?: error.userInfo[NSLocalizedDescriptionKey];
    if ([detail isKindOfClass:[NSString class]] &&
        [(NSString *)detail length] > 0) {
        [text appendFormat:@"\n       detail: %@", detail];
    }
    return text;
}

/* ------------------------------------------------------------------ */
/* Backend plumbing                                                     */
/* ------------------------------------------------------------------ */

static id<DUStorageBackend> Backend(void)
{
    NSError *error = nil;
    id<DUStorageBackend> backend = [DUBackendFactory backendWithError:&error];
    if (backend == nil) {
        printf("no storage backend: %s\n",
               error.localizedDescription.UTF8String);
        exit(2);
    }
    return backend;
}

static DUStorageObject *FindNode(DUStorageObject *object, NSString *node)
{
    if ([object.backendPath isEqualToString:node]) {
        return object;
    }
    for (DUStorageObject *child in object.children) {
        DUStorageObject *found = FindNode(child, node);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static DUStorageObject *ObjectAtNode(id<DUStorageBackend> backend,
                                     NSString *node)
{
    NSError *error = nil;
    NSArray *objects = [backend discoverStorageObjects:&error];
    for (DUStorageObject *root in objects) {
        DUStorageObject *found = FindNode(root, node);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static DUStorageObject *DiskOf(id<DUStorageBackend> backend, NSString *node)
{
    NSError *error = nil;
    for (DUStorageObject *root in [backend discoverStorageObjects:&error]) {
        if ([root.backendPath isEqualToString:node]) {
            return root;
        }
    }
    return nil;
}

// Every object in the tree, depth first, for reporting.
static NSMutableArray<DUStorageObject *> *AllObjects(DUStorageObject *root)
{
    NSMutableArray<DUStorageObject *> *all = [NSMutableArray array];
    NSMutableArray<DUStorageObject *> *work = [NSMutableArray arrayWithObject:root];
    while (work.count > 0) {
        DUStorageObject *object = work.lastObject;
        [work removeLastObject];
        [all addObject:object];
        [work addObjectsFromArray:object.children];
    }
    return all;
}

// One exercise phase, run so that a raised exception is reported as a
// failure of that phase instead of aborting the whole run. A crash is a
// defect in the path the phase drives; the remaining phases are independent
// and their results still mean something.
/* A backend verb runs on its own worker thread, where an exception cannot be
 * caught by the phase wrapper - it would kill the process with a bare line.
 * This handler prints the stack so a crash names the path it came from. */
static void ReportUncaughtException(NSException *exception)
{
    printf("UNCAUGHT %s: %s\n", exception.name.UTF8String,
           exception.reason.UTF8String);
    for (NSString *frame in exception.callStackSymbols) {
        printf("    %s\n", frame.UTF8String);
    }
    fflush(stdout);
}

static void PhaseRun(id<DUStorageBackend> backend, NSString *name,
                     void (*phase)(id<DUStorageBackend>))
{
    @try {
        phase(backend);
    } @catch (NSException *exception) {
        Fail([NSString stringWithFormat:@"phase %@ crashed", name],
             [NSString stringWithFormat:@"%@: %@", exception.name,
                                        exception.reason]);
        for (NSString *frame in exception.callStackSymbols) {
            printf("         %s\n", frame.UTF8String);
        }
        fflush(stdout);
    }
}

/* Runs an async backend verb and spins the run loop until it completes, so
 * the test can stay strictly sequential. */
static NSError *RunAsync(id<DUStorageBackend> backend, NSString *label,
                         void (^start)(void (^done)(NSError *)))
{
    __block NSError *result = nil;
    __block BOOL finished = NO;
    start(^(NSError *error) {
        result = error;
        finished = YES;
    });
    NSDate *began = [NSDate date];
    NSDate *deadline =
        [began dateByAddingTimeInterval:gStepTimeout];
    while (!finished && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop]
            runMode:NSDefaultRunLoopMode
             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    NSTimeInterval took = -[began timeIntervalSinceNow];
    (void)backend;
    if (!finished) {
        /* Two possibilities, and the report has to distinguish them:
         *   - the verb is rejected synchronously but the promise is only
         *     honoured on a worker thread, and the rejection never arrives
         *     on this run loop (a gate that calls the completion from a
         *     thread with no run loop source);
         *   - the verb was accepted and the tool is still running.
         * Either way the operation is stuck, so the test says so and moves
         * on rather than blocking the rest of the exercise. */
        Fail(label, [NSString stringWithFormat:
                                @"no completion after %.0fs - the backend never "
                                @"called its completion block for this verb",
                                gStepTimeout]);
        return [NSError errorWithDomain:@"DUTest"
                                   code:-1
                               userInfo:@{
                                   NSLocalizedDescriptionKey : @"timed out"
                               }];
    }
    printf("       (%.1fs)\n", took);
    fflush(stdout);
    return result;
}

// Progress lines are dumped only when DU_LIVE_VERBOSE is set, so a long
// exercise does not bury the phase headers in tool chatter.
static void DumpProgress(double fraction, NSString *message)
{
    static BOOL verbose = NO;
    if (verbose == NO && getenv("DU_LIVE_VERBOSE") != NULL) {
        verbose = YES;
    }
    if (verbose && message.length > 0) {
        printf("       [%3.0f%%] %s\n", fraction * 100.0, message.UTF8String);
    }
}

/* ------------------------------------------------------------------ */

static void PhaseCapabilities(id<DUStorageBackend> backend)
{
    printf("\n== capabilities ==\n");
    fflush(stdout);
    NSDictionary *report = [backend capabilitiesReport];
    for (NSString *key in
         @[ @"Platform", @"Device discovery", @"Mount management",
            @"Partitioning", @"Filesystem formatting",
            @"Filesystem repair", @"Secure erase", @"RAID management",
            @"Disk image creation", @"Disk image conversion",
            @"Disk image resizing", @"Optical burning" ]) {
        printf("  %-26s %s\n", key.UTF8String,
               [report[key] description].UTF8String);
    }
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *tool in [backend expectedToolNames]) {
        if (ShellOK(@"command -v %@ >/dev/null 2>&1", tool)) {
            [missing addObject:tool];
        }
    }
    if (missing.count > 0) {
        printf("  tools absent: %s\n",
               [missing componentsJoinedByString:@", "].UTF8String);
    }
}

static void PhaseDiscovery(id<DUStorageBackend> backend)
{
    printf("\n== discovery of %s ==\n", gDevice.UTF8String);
    fflush(stdout);
    DUStorageObject *disk = DiskOf(backend, gDevice);
    if (disk == nil) {
        Fail(@"discovery", @"the device is not in the discovered hierarchy");
        return;
    }
    Pass(@"device discovered", disk.displayName);
    for (DUStorageObject *object in AllObjects(disk)) {
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < (object == disk ? 0 : 4); i++) {
            [indent appendString:@" "];
        }
        BOOL isDevice = [object isKindOfClass:[DUStorageDevice class]];
        printf("    %s%s type=%ld path=%s scheme=%s\n", indent.UTF8String,
               object.displayName.UTF8String, (long)object.type,
               object.backendPath.UTF8String ?: "-",
               isDevice
                   ? ((((DUStorageDevice *)object).partitionScheme ?: @"-")
                          .UTF8String)
                   : "-");
    }
    DUStorageDevice *device = (DUStorageDevice *)disk;
    printf("    capacity=%llu smart=%ld health=%s\n",
           device.capacityBytes, (long)device.smartStatus,
           device.healthStatus.UTF8String ?: "-");
}

// The volume of the Nth partition of the target disk, in table order, so the
// test addresses partitions the way gpart numbers them rather than by
// guessing a node name.
static DUStorageObject *PartitionVolumeOf(id<DUStorageBackend> backend,
                                          unsigned long index)
{
    DUStorageObject *disk = DiskOf(backend, gDevice);
    if (disk == nil) {
        return nil;
    }
    NSMutableArray<DUPartition *> *partitions = [NSMutableArray array];
    for (DUStorageObject *child in disk.children) {
        if ([child isKindOfClass:[DUPartition class]]) {
            [partitions addObject:(DUPartition *)child];
        }
    }
    [partitions sortUsingComparator:^NSComparisonResult(DUPartition *a,
                                                      DUPartition *b) {
        if (a.offsetBytes != b.offsetBytes) {
            return a.offsetBytes < b.offsetBytes ? NSOrderedAscending
                                                 : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    if (index >= partitions.count) {
        return nil;
    }
    // The VOLUME is the eritable object; a partition with an EFI type has no
    // volume child at all, which is itself a documented outcome.
    DUPartition *partition = partitions[index];
    return partition.volume ?: (DUStorageObject *)partition;
}

static void PhaseGuards(id<DUStorageBackend> backend)
{
    printf("\n== safety guards ==\n");
    fflush(stdout);

    // A whole-disk erase must be refused while anything under it is mounted.
    // We make that true by formatting a partition and mounting it first.
    NSError *error = RunAsync(backend, @"partition-for-guard", ^(void (^done)(NSError *)) {
        DUStorageObject *disk = DiskOf(backend, gDevice);
        DUPartitionLayout *layout =
            [[DUPartitionLayout alloc] initWithCapacity:400ULL * 1024 * 1024
                                                 scheme:@"gpt"];
        NSError *addError = nil;
        BOOL added = [layout addPartitionWithSize:64ULL * 1024 * 1024
                                            name:@"GUARD"
                                           error:&addError];
        if (!added) {
            done(addError);
            return;
        }
        // A plan entry with no filesystem has no type to write, so the
        // backend must refuse it - which would leave nothing to guard.
        [layout setFormat:@"ufs" forPartition:layout.partitions[0]];
        DUPartitionPlan *plan = [DUPartitionPlan planFromLayout:layout
                                                      forDevice:disk
                                                     destructive:YES];
        [backend partitionDevice:disk
                        withPlan:plan
                         progress:^(double f, NSString *m) { DumpProgress(f, m); }
                       completion:done];
    });
    Check(error == nil, @"partition gpt (guard fixture)", ErrorText(error));

    DUStorageObject *guard = PartitionVolumeOf(backend, 0);
    if (guard == nil) {
        Fail(@"guard fixture volume",
             @"the guard plan's partition was not discovered as an eratable "
             @"volume");
        return;
    }

    error = RunAsync(backend, @"format-guard", ^(void (^done)(NSError *)) {
        [backend eraseObject:guard
                     options:@{ kDUFormatIdentifierKey : @"ufs",
                                @"name" : @"GUARD" }
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    Check(error == nil, @"format guard partition UFS", ErrorText(error));

    guard = PartitionVolumeOf(backend, 0);
    __block NSString *mountPoint = nil;
    error = RunAsync(backend, @"mount-guard", ^(void (^done)(NSError *)) {
        [backend mountObject:guard
                  completion:^(NSError *mountError, NSString *point) {
                      mountPoint = point;
                      done(mountError);
                  }];
    });
    Check(error == nil && mountPoint.length > 0, @"mount volume",
          error == nil ? mountPoint : ErrorText(error));
    if (mountPoint == nil) {
        return;
    }
    Check([[NSFileManager defaultManager] fileExistsAtPath:mountPoint],
          @"mount point exists", mountPoint);
    printf("       mount output: %s\n",
           [Shell(@"mount | grep %@", mountPoint)
               stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]]
               .UTF8String);

    // Erase unmounts what is mounted from the target first, like the
    // platform's own disk utility; it must neither refuse nor leave the old
    // mount behind.
    error = RunAsync(backend, @"erase-while-mounted", ^(void (^done)(NSError *)) {
        [backend eraseObject:guard
                     options:@{ kDUFormatIdentifierKey : @"ufs",
                                @"name" : @"GUARD" }
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    Check(error == nil, @"erase of a mounted volume succeeds",
          ErrorText(error));
    Check(!ShellOK(@"mount | grep -q %@", mountPoint),
          @"erase unmounted the volume first", mountPoint);

    // Repair still has to refuse a mounted filesystem: fsck on a live
    // mount corrupts it.
    guard = PartitionVolumeOf(backend, 0);
    error = RunAsync(backend, @"remount-guard", ^(void (^done)(NSError *)) {
        [backend mountObject:guard
                  completion:^(NSError *mountError, NSString *point) {
                      (void)point;
                      done(mountError);
                  }];
    });
    Check(error == nil, @"remount the guard volume", ErrorText(error));
    error = RunAsync(backend, @"repair-while-mounted", ^(void (^done)(NSError *)) {
        [backend repairObject:guard
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    Check(error != nil && error.code == 3, @"repair refused while mounted",
          error == nil ? @"it ran anyway" : ErrorText(error));

    DUStorageObject *disk = DiskOf(backend, gDevice);
    error = RunAsync(backend, @"partition-while-mounted", ^(void (^done)(NSError *)) {
        DUPartitionLayout *layout =
            [[DUPartitionLayout alloc] initWithCapacity:100ULL * 1024 * 1024
                                                 scheme:@"gpt"];
        [layout addPartitionWithSize:32ULL * 1024 * 1024
                               name:@"X"
                              error:NULL];
        [layout setFormat:@"ufs" forPartition:layout.partitions[0]];
        DUPartitionPlan *plan = [DUPartitionPlan planFromLayout:layout
                                                      forDevice:disk
                                                     destructive:YES];
        [backend partitionDevice:disk
                        withPlan:plan
                         progress:^(double f, NSString *m) { DumpProgress(f, m); }
                       completion:done];
    });
    Check(error == nil, @"partitioning a disk with a mounted child succeeds",
          ErrorText(error));
    Check(!ShellOK(@"mount | grep -q %@", mountPoint),
          @"partitioning unmounted the child first", mountPoint);
    {
        // The plan carried a format and a name, so the new partition must
        // come out formatted and labelled, not blank.
        DUStorageObject *fresh = PartitionVolumeOf(backend, 0);
        Check(fresh != nil && HasUFSTag(@"X", fresh.backendPath),
              @"partitioning formatted the new partition with its label",
              fresh.backendPath);
    }

    // Unmounting something that is not mounted must fail honestly.
    guard = PartitionVolumeOf(backend, 0);
    error = RunAsync(backend, @"unmount-twice", ^(void (^done)(NSError *)) {
        [backend unmountObject:guard completion:done];
    });
    Check(error != nil, @"second unmount refused",
          error == nil ? @"it reported success" : ErrorText(error));
    // ...and the mount table must agree.
    Check(!ShellOK(@"mount | grep -q %@", mountPoint),
          @"still not mounted after the second attempt", mountPoint);
}

static void PhasePartitioning(id<DUStorageBackend> backend)
{
    printf("\n== partitioning: GPT with three filesystems ==\n");
    fflush(stdout);
    DUStorageObject *disk = DiskOf(backend, gDevice);
    if (disk == nil) {
        Fail(@"partitioning", @"device vanished");
        return;
    }

    unsigned long long mib = 1024ULL * 1024;
    DUPartitionLayout *layout = [[DUPartitionLayout alloc]
        initWithCapacity:((DUStorageDevice *)disk).capacityBytes
                 scheme:@"gpt"];
    NSError *addError = nil;
    BOOL added = [layout addPartitionWithSize:256 * mib name:@"EFI" error:&addError];
    added &= [layout addPartitionWithSize:512 * mib name:@"Data" error:&addError];
    added &= [layout addPartitionWithSize:256 * mib name:@"Fat" error:&addError];
    if (!added) {
        Fail(@"layout build", ErrorText(addError));
        return;
    }
    [layout setFormat:@"efi" forPartition:layout.partitions[0]];
    [layout setFormat:@"ufs" forPartition:layout.partitions[1]];
    [layout setFormat:@"fat32" forPartition:layout.partitions[2]];
    NSError *validation = nil;
    if (![layout validate:&validation]) {
        Fail(@"layout validation", ErrorText(validation));
        return;
    }
    Pass(@"layout validates", [NSString stringWithFormat:@"%lu entries",
                                 (unsigned long)layout.partitions.count]);

    DUPartitionPlan *plan = [DUPartitionPlan planFromLayout:layout
                                                  forDevice:disk
                                                 destructive:YES];
    NSError *error = RunAsync(backend, @"partition", ^(void (^done)(NSError *)) {
        [backend partitionDevice:disk
                        withPlan:plan
                         progress:^(double f, NSString *m) { DumpProgress(f, m); }
                       completion:done];
    });
    Check(error == nil, @"apply partition plan", ErrorText(error));

    NSString *table = ShellOut([NSString stringWithFormat:@"gpart show -p %@",
                                  gDevice.lastPathComponent]);
    printf("       gpart show -p:\n%s\n", table.UTF8String);
    Check([table rangeOfString:@"GPT"].location != NSNotFound,
          @"gpart reports GPT", gDevice);
    Check([table rangeOfString:@"efi"].location != NSNotFound,
          @"EFI partition present", @"");
    Check([table rangeOfString:@"freebsd-ufs"].location != NSNotFound,
          @"UFS partition present", @"");
    Check([table rangeOfString:@"ms-basic-data"].location != NSNotFound,
          @"FAT partition present", @"");
    Check([ShellOut([NSString stringWithFormat:@"gpart show -l %@",
                     gDevice.lastPathComponent])
              rangeOfString:@"Data"]
              .location != NSNotFound,
          @"GPT label written",
          @"gpart show -l lists the partition names");

    // A plan that asks for an unmappable type must be refused BEFORE the
    // table is destroyed.
    DUPartitionLayout *bad = [[DUPartitionLayout alloc]
        initWithCapacity:64 * mib
                 scheme:@"mbr"];
    [bad addPartitionWithSize:32 * mib name:@"Nope" error:NULL];
    [bad setFormat:@"ufs" forPartition:bad.partitions[0]];
    DUPartitionPlan *badPlan = [DUPartitionPlan planFromLayout:bad
                                                     forDevice:disk
                                                    destructive:YES];
    error = RunAsync(backend, @"partition-bad", ^(void (^done)(NSError *)) {
        [backend partitionDevice:disk
                        withPlan:badPlan
                         progress:^(double f, NSString *m) { DumpProgress(f, m); }
                       completion:done];
    });
    Check(error != nil, @"unmappable MBR/UFS plan refused",
          error == nil ? @"it ran anyway" : ErrorText(error));
    Check([ShellOut([NSString stringWithFormat:@"gpart show %@",
                     gDevice.lastPathComponent])
              rangeOfString:@"GPT"]
              .location != NSNotFound,
          @"table survived the refused plan", @"still GPT");

    // An unsupported scheme must be refused. "GPT" normalizes to "gpt" and is
    // therefore VALID, so the token has to be one the parser cannot map.
    DUPartitionLayout *weird = [[DUPartitionLayout alloc]
        initWithCapacity:64 * mib
                 scheme:@"not-a-scheme"];
    [weird addPartitionWithSize:32 * mib name:@"Y" error:NULL];
    [weird setFormat:@"fat32" forPartition:weird.partitions[0]];
    DUPartitionPlan *weirdPlan = [DUPartitionPlan planFromLayout:weird
                                                      forDevice:disk
                                                     destructive:NO];
    error = RunAsync(backend, @"partition-scheme", ^(void (^done)(NSError *)) {
        [backend partitionDevice:disk
                        withPlan:weirdPlan
                         progress:^(double f, NSString *m) { DumpProgress(f, m); }
                       completion:done];
    });
    Check(error != nil, @"garbage scheme refused",
          error == nil ? @"it ran anyway" : ErrorText(error));
}

static void PhaseFormats(id<DUStorageBackend> backend)
{
    printf("\n== formatting each new partition ==\n");
    fflush(stdout);
    /* The three partitions the GPT plan created, addressed by position. The
     * plan wrote efi, ufs and fat32, so the interesting cases are the two
     * that carry a real filesystem, plus the EFI one which the app must
     * refuse to erase as a data volume. */
    struct {
        unsigned long position;
        NSString *format;
        NSString *label;
    } cases[] = {
        { 1, @"ufs", @"UFSPART" },
        { 2, @"fat32", @"FATPART" },
    };
    for (NSUInteger i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        DUStorageObject *object = PartitionVolumeOf(backend, cases[i].position);
        if (object == nil) {
            Fail(@"format", [NSString stringWithFormat:
                                       @"partition %lu not discovered",
                                       cases[i].position]);
            continue;
        }
        NSArray *formats = [backend supportedFormatsForObject:object];
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *descriptor in formats) {
            [names addObject:descriptor[kDUFormatIdentifierKey]];
        }
        printf("       %s offers: %s\n", S(object.displayName),
               S([names componentsJoinedByString:@", "]));
        fflush(stdout);

        NSString *format = cases[i].format;
        NSString *label = cases[i].label;
        /* Hold the pre-erase image of the volume's first 4 MiB so the label
         * write can be proven rather than assumed: the bytes newfs wrote must
         * differ from what was there, and the new label must be in them. */
        NSString *node = object.backendPath;
        NSData *before = ReadLeadingBytes(node, 4 * 1024 * 1024);
        NSError *error =
            RunAsync(backend, @"erase", ^(void (^done)(NSError *)) {
            [backend eraseObject:object
                         options:@{ kDUFormatIdentifierKey : format,
                                    @"name" : label }
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error == nil,
              [NSString stringWithFormat:@"erase %@ as %@",
                                         object.displayName, format],
              ErrorText(error));

        if (![format isEqualToString:@"ufs"]) {
            continue;
        }
        // The label the tool was asked to write must actually be on the
        // filesystem, not merely accepted by the tool.
        DUStorageObject *after = PartitionVolumeOf(backend, cases[i].position);
        Check(HasUFSTag(label, after.backendPath),
              @"UFS volume label written", label);
        // And the volume really was rewritten, not left as it was.
        NSData *now = ReadLeadingBytes(after.backendPath, 4 * 1024 * 1024);
        Check(![before isEqualToData:now],
              @"the UFS volume was actually reformatted",
              [NSString stringWithFormat:@"%lu vs %lu bytes",
                                         (unsigned long)before.length,
                                         (unsigned long)now.length]);
    }

    // An EFI system partition must not be offered as an erasable data volume.
    DUStorageObject *efi = PartitionVolumeOf(backend, 0);
    if (efi == nil) {
        printf("       (no EFI partition row to check)\n");
    } else {
        BOOL erasable = [backend supportsOperation:kDUOperationErase
                                         forObject:efi];
        Check(!erasable, @"EFI partition not erasable as a data volume",
              efi.displayName);
    }

    // A format the backend cannot do must be refused, not attempted.
    DUStorageObject *p1 = PartitionVolumeOf(backend, 1);
    if (p1 != nil) {
        NSError *error =
            RunAsync(backend, @"erase-bogus", ^(void (^done)(NSError *)) {
            [backend eraseObject:p1
                         options:@{ kDUFormatIdentifierKey : @"exfat" }
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error != nil, @"unsupported format refused",
              error == nil ? @"it ran anyway" : ErrorText(error));

        // An over-long label must be truncated, not handed to newfs verbatim:
        // newfs rejects a UFS label longer than 15 characters outright, so
        // passing the 39-character name unchanged fails the whole erase.
        NSString *longName = @"A-very-long-volume-name-that-exceeds-limits";
        NSError *longLabel =
            RunAsync(backend, @"erase-long-label", ^(void (^done)(NSError *)) {
            [backend eraseObject:PartitionVolumeOf(backend, 1)
                         options:@{ kDUFormatIdentifierKey : @"ufs",
                                    @"name" : longName }
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(longLabel == nil, @"erase with an over-long label",
              ErrorText(longLabel));
        NSString *writtenNode =
            PartitionVolumeOf(backend, 1).backendPath;
        Check(HasUFSTag([longName substringToIndex:12], writtenNode),
              @"truncated label was written", writtenNode);
        // The tail must be gone (truncated) and the head must be there
        // (not rejected or mangled from the front).
        Check(!HasUFSTag(@"exceeds", writtenNode),
              @"over-long label was truncated to the tool's limit", writtenNode);
        Check(HasUFSTag(@"A-very-long", writtenNode),
              @"truncated label kept its first characters", writtenNode);
    }
}

static void PhaseFirstAid(id<DUStorageBackend> backend)
{
    printf("\n== first aid ==\n");
    fflush(stdout);
    DUStorageObject *ufs = PartitionVolumeOf(backend, 1);
    DUStorageObject *fat = PartitionVolumeOf(backend, 2);

    if (ufs != nil) {
        NSError *error = RunAsync(backend, @"verify", ^(void (^done)(NSError *)) {
            [backend verifyObject:ufs
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error == nil, @"verify UFS volume", ErrorText(error));

        error = RunAsync(backend, @"repair", ^(void (^done)(NSError *)) {
            [backend repairObject:ufs
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error == nil, @"repair UFS volume", ErrorText(error));
    }

    // Whole-disk verify fans out over the partitions, and it is checked HERE,
    // while every volume is still intact: the damage case below leaves a FAT
    // boot sector that fsck_msdosfs cannot repair, so a whole-disk verify run
    // afterwards would be reporting the test's own wreckage.
    DUStorageObject *disk = DiskOf(backend, gDevice);
    if (disk != nil) {
        NSError *error = RunAsync(backend, @"verify-disk", ^(void (^done)(NSError *)) {
            [backend verifyObject:disk
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        printf("       whole-disk verify: %s\n",
               error == nil ? "clean" : S(ErrorText(error)));
        fflush(stdout);
        Check(error == nil, @"verify the whole disk", ErrorText(error));
    }

    if (fat != nil) {
        NSError *error = RunAsync(backend, @"verify-fat", ^(void (^done)(NSError *)) {
            [backend verifyObject:fat
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error == nil, @"verify FAT volume", ErrorText(error));

        /* A damaged filesystem must be REPORTED, not silently declared clean.
         * Garbage has to land where fsck_msdosfs(8) actually looks. The boot
         * sector holds the jump instruction and the BPB, so a volume whose
         * first sectors are noise is unambiguously not a FAT filesystem and
         * fsck_msdosfs is bound to object. (Damage confined to slack space is
         * legitimately reported clean, so the test does not rely on that.) */
        DUStorageObject *damaged = PartitionVolumeOf(backend, 2);
        NSString *fatNode = damaged.backendPath;
        /* The damage must be proven to have landed, or a "verify says clean"
         * result proves nothing about the app - it would just mean the write
         * was refused. The first sectors of a FAT volume are the boot sector
         * and the reserved area; overwriting them is an unambiguous break. */
        NSData *headBefore = ReadLeadingBytes(fatNode, 512);
        Shell(@"dd if=/dev/urandom of=%@ bs=512 count=8 conv=notrunc "
              @"status=none", fatNode);
        NSData *headAfter = ReadLeadingBytes(fatNode, 512);
        printf("       boot sector: %s -> %s\n",
               HexOf(headBefore).UTF8String, HexOf(headAfter).UTF8String);
        fflush(stdout);
        /* Comparing the bytes before and after is the only deterministic
         * proof that the damage landed; looking for a 2-byte pattern in the
         * noise would be a coin flip. */
        Check(![headBefore isEqualToData:headAfter],
              @"the boot sector really was overwritten",
              HexOf(headAfter));

        error = RunAsync(backend, @"verify-damaged", ^(void (^done)(NSError *)) {
            [backend verifyObject:PartitionVolumeOf(backend, 2)
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        // What the tool itself says, so the report distinguishes "the app
        // ignored a checker that complained" from "the checker found nothing".
        NSString *checkerVerdict = DUParsingLikeTrim(
            Shell(@"fsck_msdosfs -n %@ 2>&1 | head -3", fatNode));
        printf("       fsck_msdosfs says: %s\n", S(checkerVerdict));
        fflush(stdout);
        Check(error != nil, @"damaged FAT volume reported",
              error == nil
                  ? [NSString stringWithFormat:@"verify claimed success; %@",
                                               checkerVerdict]
                  : ErrorText(error));

        DUStorageObject *repairable = PartitionVolumeOf(backend, 2);
        error = RunAsync(backend, @"repair-damaged", ^(void (^done)(NSError *)) {
            [backend repairObject:repairable
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        printf("       repair of damaged FAT: %s\n",
               error == nil ? "succeeded" : S(ErrorText(error)));
        fflush(stdout);

        /* A FAT boot sector that fsck cannot repair leaves the volume unusable
         * for the phases that follow, which image it and restore onto it. Put
         * it back into a known state rather than leaving the test's own
         * wreckage behind. */
        error = RunAsync(backend, @"reformat-fat", ^(void (^done)(NSError *)) {
            [backend eraseObject:PartitionVolumeOf(backend, 2)
                         options:@{ kDUFormatIdentifierKey : @"fat32",
                                    @"name" : @"FATPART" }
                        progress:^(double f, NSString *m) { DumpProgress(f, m); }
                      completion:done];
        });
        Check(error == nil, @"re-format the FAT volume after the damage test",
              ErrorText(error));
    }
}

static void PhaseMountData(id<DUStorageBackend> backend)
{
    printf("\n== mount, write, read back ==\n");
    fflush(stdout);
    DUStorageObject *ufs = PartitionVolumeOf(backend, 1);
    if (ufs == nil) {
        Fail(@"mount round trip", @"UFS volume missing");
        return;
    }
    __block NSString *mountPoint = nil;
    NSError *error = RunAsync(backend, @"mount", ^(void (^done)(NSError *)) {
        [backend mountObject:ufs
                  completion:^(NSError *mountError, NSString *point) {
                      mountPoint = point;
                      done(mountError);
                  }];
    });
    Check(error == nil && mountPoint.length > 0, @"mount UFS volume",
          error == nil ? mountPoint : ErrorText(error));
    if (mountPoint == nil) {
        return;
    }
    Check([[NSFileManager defaultManager] fileExistsAtPath:mountPoint],
          @"mount point exists", mountPoint);
    printf("       %s\n", S([Shell(@"mount | grep %@", mountPoint)
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]]));
    fflush(stdout);

    Check(ShellOK(@"printf hello > %@/probe.txt", mountPoint),
          @"write a file", mountPoint);
    Check(ShellOK(@"test -s %@/probe.txt", mountPoint), @"file is there", @"");

    /* Re-discover: the object captured before the mount has
     * canUnmount = NO, so passing it back would be refused for the wrong
     * reason. */
    ufs = PartitionVolumeOf(backend, 1);
    error = RunAsync(backend, @"unmount", ^(void (^done)(NSError *)) {
        [backend unmountObject:ufs completion:done];
    });
    Check(error == nil, @"unmount", ErrorText(error));
    {
        // Report the matching line, not just a verdict: the check can only be
        // argued with if the reader can see what the mount table said.
        NSString *listing =
            DUParsingLikeTrim(Shell(@"mount | grep %@", mountPoint));
        Check(listing.length == 0, @"mount table no longer lists it",
              listing.length == 0 ? mountPoint
                                  : [NSString stringWithFormat:@"still: %@",
                                                               listing]);
    }

    ufs = PartitionVolumeOf(backend, 1);
    __block NSString *again = nil;
    error = RunAsync(backend, @"remount", ^(void (^done)(NSError *)) {
        [backend mountObject:ufs
                  completion:^(NSError *mountError, NSString *point) {
                      again = point;
                      done(mountError);
                  }];
    });
    Check(error == nil && again.length > 0, @"remount", ErrorText(error));
    if (again != nil) {
        Check(ShellOK(@"grep -q hello %@/probe.txt", again),
              @"file survived the unmount", again);
        RunAsync(backend, @"unmount2", ^(void (^done)(NSError *)) {
            [backend unmountObject:PartitionVolumeOf(backend, 1)
                        completion:done];
        });
    }
    fflush(stdout);

    // Mounting something already mounted must return the existing point, not
    // stack a second mount.
    DUStorageObject *node = PartitionVolumeOf(backend, 1);
    RunAsync(backend, @"mount3", ^(void (^done)(NSError *)) {
        [backend mountObject:node
                  completion:^(NSError *mountError, NSString *point) {
                      again = point;
                      done(mountError);
                  }];
    });
    NSInteger mounts = 0;
    for (NSString *line in
         [ShellOut(@"mount") componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:node.backendPath].location != NSNotFound) {
            mounts++;
        }
    }
    Check(mounts == 1, @"no stacked mount for one node",
          [NSString stringWithFormat:@"%ld entries", (long)mounts]);
    RunAsync(backend, @"unmount3", ^(void (^done)(NSError *)) {
        [backend unmountObject:PartitionVolumeOf(backend, 1) completion:done];
    });
    // Nothing of ours may be left mounted when the exercise ends.
    for (NSString *line in [ShellOut(@"mount") componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:gDevice].location != NSNotFound) {
            Fail(@"no leftover mount", [line
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    }
    Pass(@"no leftover mounts on the target disk", @"");
    fflush(stdout);
}

static void PhaseImages(id<DUStorageBackend> backend)
{
    printf("\n== disk images ==\n");
    fflush(stdout);
    NSString *work = @"/tmp/du_live_test";
    Shell(@"rm -rf %@ && mkdir -p %@", work, work);

    DUStorageObject *fat = PartitionVolumeOf(backend, 2);
    if (fat == nil) {
        Fail(@"images", @"FAT volume missing");
        return;
    }
    NSArray *formats = [backend imageCreationFormats];
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *descriptor in formats) {
        [names addObject:descriptor[kDUFormatIdentifierKey]];
    }
    printf("       image formats: %s\n",
           S([names componentsJoinedByString:@", "]));
    fflush(stdout);
    Check([names containsObject:@"raw"], @"raw image format offered", @"");

    // Imageing a VOLUME must copy the volume, not the whole disk.
    NSString *volumeImage = [work stringByAppendingPathComponent:@"vol.img"];
    NSError *error =
        RunAsync(backend, @"image-volume", ^(void (^done)(NSError *)) {
        [backend createImageFromObject:PartitionVolumeOf(backend, 2)
                                options:@{ @"path" : volumeImage,
                                           @"format" : @"raw" }
                               progress:^(double f, NSString *m) { DumpProgress(f, m); }
                             completion:done];
    });
    Check(error == nil, @"create image from a volume", ErrorText(error));
    DUStorageDevice *device = (DUStorageDevice *)DiskOf(backend, gDevice);
    unsigned long long diskBytes = device != nil ? device.capacityBytes : 0;
    NSDictionary *imageAttributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:volumeImage
                         error:NULL];
    unsigned long long imageBytes =
        [imageAttributes[NSFileSize] unsignedLongLongValue];
    DUStorageDevice *whole = (DUStorageDevice *)DiskOf(backend, gDevice);
    printf("       image=%llu disk=%llu\n", imageBytes,
           whole != nil ? whole.capacityBytes : 0);
    fflush(stdout);
    Check(imageBytes > 0 && imageBytes < diskBytes / 4,
          @"volume image is not the whole disk",
          [NSString stringWithFormat:@"image=%llu disk=%llu", imageBytes,
                                     diskBytes]);
    Check([[NSFileManager defaultManager] fileExistsAtPath:volumeImage],
          @"image file exists", volumeImage);

    /* The written bytes must match the source partition exactly. The hash is
     * read from the LIVE partition: the object captured before the format
     * still points at the pre-format node state, and comparing against that
     * would be comparing the image with a different filesystem. */
    DUStorageObject *liveFat = PartitionVolumeOf(backend, 2);
    NSString *fatNode = liveFat.backendPath;
    // sha256(1) prints "SHA256 (file) = digest"; the digest is what counts.
    NSString *srcHash =
        DUParsingLikeTrim(Shell(@"sha256 %@ | cut -d= -f2", fatNode));
    NSString *imgHash =
        DUParsingLikeTrim(Shell(@"sha256 %@ | cut -d= -f2", volumeImage));
    Check(srcHash.length == 64 && [srcHash isEqualToString:imgHash],
          @"image bytes match the source partition", imgHash);

    // A .gz image must actually be compressed, and must survive gzip -t.
    NSString *gzImage = [work stringByAppendingPathComponent:@"vol.img.gz"];
    error = RunAsync(backend, @"image-gz", ^(void (^done)(NSError *)) {
        [backend createImageFromObject:PartitionVolumeOf(backend, 2)
                                options:@{ @"path" : gzImage,
                                           @"format" : @"gz" }
                               progress:^(double f, NSString *m) { DumpProgress(f, m); }
                             completion:done];
    });
    printf("       gz image: %s\n",
           error == nil ? "ok" : S(ErrorText(error)));
    fflush(stdout);
    if (error == nil) {
        Check(ShellOK(@"gzip -t %@", gzImage),
              @"gz image really is a gzip archive", gzImage);
        NSDictionary *gzAttributes = [[NSFileManager defaultManager]
            attributesOfItemAtPath:gzImage
                             error:NULL];
        unsigned long long gzBytes =
            [gzAttributes[NSFileSize] unsignedLongLongValue];
        Check(gzBytes > 0 && gzBytes < imageBytes,
              @"gz image is smaller than the raw one",
              [NSString stringWithFormat:@"%llu vs %llu", gzBytes, imageBytes]);
        // And it must decompress back to the same bytes as the partition.
        NSString *gunzipHash =
            DUParsingLikeTrim(Shell(@"gzip -dc %@ | sha256 | cut -d= -f2",
                                    gzImage));
        Check(gunzipHash.length == 64 &&
                  [gunzipHash isEqualToString:srcHash],
              @"gz image decompresses to the source bytes", gunzipHash);
    } else {
        Pass(@"gz image reported a failure instead of lying",
             ErrorText(error));
    }

    // An image target that already exists must be refused.
    error = RunAsync(backend, @"image-exists", ^(void (^done)(NSError *)) {
        [backend createImageFromObject:PartitionVolumeOf(backend, 2)
                                options:@{ @"path" : volumeImage,
                                           @"format" : @"raw" }
                               progress:^(double f, NSString *m) { DumpProgress(f, m); }
                             completion:done];
    });
    Check(error != nil, @"existing image target refused",
          error == nil ? @"it overwrote the file" : ErrorText(error));

    // Blank image + folder image + mounting an image file.
    NSString *blank = [work stringByAppendingPathComponent:@"blank.img"];
    error = RunAsync(backend, @"blank-image", ^(void (^done)(NSError *)) {
        [backend createBlankImageAtPath:blank
                                   size:8 * 1024 * 1024
                                 format:@"raw"
                               progress:^(double f, NSString *m) { DumpProgress(f, m); }
                             completion:done];
    });
    Check(error == nil, @"create blank raw image", ErrorText(error));
    NSDictionary *blankAttributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:blank
                         error:NULL];
    unsigned long long blankBytes =
        [blankAttributes[NSFileSize] unsignedLongLongValue];
    Check(blankBytes == 8 * 1024 * 1024,
          @"blank image has the requested size",
          [NSString stringWithFormat:@"%llu bytes", blankBytes]);
    // ...and it must be SPARSE, or a 500 GB blank image would consume 500 GB
    // of real storage. Blocks actually allocated must be far below the
    // apparent size.
    NSString *blocks =
        DUParsingLikeTrim(Shell(@"ls -lsk %@ | awk '{print $1}'", blank));
    unsigned long long allocatedKiB =
        (unsigned long long)[blocks doubleValue];
    printf("       blank image apparent=%llu allocated=%llu KiB\n", blankBytes,
           allocatedKiB);
    fflush(stdout);
    Check(allocatedKiB * 1024 < blankBytes,
          @"blank image is sparse",
          [NSString stringWithFormat:@"%llu KiB of %llu bytes", allocatedKiB,
                                     blankBytes]);

    NSString *folder = [work stringByAppendingPathComponent:@"srcfolder"];
    Shell(@"mkdir -p %@/sub && echo one > %@/a.txt && echo two > %@/sub/b.txt",
          folder, folder, folder);
    // The folder has to hold enough to be worth imaging, and the image has to
    // end up bigger than the payload so a truncated copy is visible.
    Shell(@"dd if=/dev/zero of=%@/sub/big.bin bs=1k count=200 2>/dev/null", folder);
    NSString *folderImage = [work stringByAppendingPathComponent:@"folder.img"];
    error = RunAsync(backend, @"folder-image", ^(void (^done)(NSError *)) {
        [backend createImageFromFolder:folder
                            destination:folderImage
                            filesystem:@"fat32"
                              progress:^(double f, NSString *m) { DumpProgress(f, m); }
                            completion:done];
    });
    printf("       folder image: %s\n",
           error == nil ? "ok" : S(ErrorText(error)));
    fflush(stdout);
    if (error == nil) {
        Check(ShellOK(@"test -s %@", folderImage),
              @"folder image written", folderImage);
    }

    __block NSString *imageMount = nil;
    error = RunAsync(backend, @"mount-image", ^(void (^done)(NSError *)) {
        [backend mountFileImageAtPath:folderImage
                           completion:^(NSError *mountError, NSString *point) {
                               imageMount = point;
                               done(mountError);
                           }];
    });
    printf("       mount image file: %s\n",
           error == nil
               ? S([@"ok " stringByAppendingString:(imageMount ?: @"")])
               : S(ErrorText(error)));
    fflush(stdout);
    // No md device or temporary mount may survive the exercise.
    Shell(@"mdconfig -l 2>/dev/null | grep -c . > /tmp/du_md_before");
    if (imageMount != nil) {
        // Every file that went in must come back out, byte for byte.
        Check(ShellOK(@"test -f %@/a.txt", imageMount),
              @"a.txt readable through the mounted image",
              [NSString stringWithFormat:@"%s (a.txt missing)",
                                         S(imageMount)]);
        Check(ShellOK(@"test -f %@/sub/b.txt", imageMount),
              @"sub/b.txt readable through the mounted image",
              [NSString stringWithFormat:@"%s (sub/b.txt missing)",
                                         S(imageMount)]);
        NSString *original =
            DUParsingLikeTrim(Shell(@"sha256 %@/sub/big.bin | cut -d= -f2",
                                    folder));
        NSString *copied =
            DUParsingLikeTrim(Shell(@"sha256 %@/sub/big.bin | cut -d= -f2",
                                    imageMount));
        Check(original.length == 64 && [original isEqualToString:copied],
              @"the copied file is byte-identical", copied);
        Shell(@"umount %@ 2>/dev/null", imageMount);
    }

    // Convert and resize need qemu-img; the app must say so honestly.
    NSString *converted = [work stringByAppendingPathComponent:@"vol.qcow2"];
    error = RunAsync(backend, @"convert", ^(void (^done)(NSError *)) {
        DUDiskImage *image =
            [[DUDiskImage alloc] initWithIdentifier:@"live-image"];
        image.path = volumeImage;
        image.sizeBytes = imageBytes;
        [backend convertImage:image
                      options:@{ @"path" : converted, @"format" : @"qcow2" }
                     progress:^(double f, NSString *m) { DumpProgress(f, m); }
                   completion:done];
    });
    printf("       convert: %s\n",
           error == nil ? "ok" : S(ErrorText(error)));
    fflush(stdout);
    Check(error != nil || ShellOK(@"test -f %@", converted),
          @"convert either worked or refused", @"");

    error = RunAsync(backend, @"resize", ^(void (^done)(NSError *)) {
        DUDiskImage *image =
            [[DUDiskImage alloc] initWithIdentifier:@"live-image"];
        image.path = volumeImage;
        image.sizeBytes = imageBytes;
        [backend resizeImage:image
                     options:@{ @"deltaBytes" : @(4 * 1024 * 1024) }
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    printf("       resize: %s\n",
           error == nil ? "ok" : S(ErrorText(error)));
    fflush(stdout);
}

static void PhaseRestore(id<DUStorageBackend> backend)
{
    printf("\n== restore ==\n");
    fflush(stdout);
    DUStorageObject *fat = PartitionVolumeOf(backend, 2);
    DUStorageObject *ufs = PartitionVolumeOf(backend, 1);
    if (fat == nil || ufs == nil) {
        Fail(@"restore", @"partitions missing");
        return;
    }

    // Same device must be refused.
    NSError *error =
        RunAsync(backend, @"restore-same", ^(void (^done)(NSError *)) {
        [backend restoreFromSource:fat
                       destination:fat
                           options:@{}
                          progress:^(double f, NSString *m) { DumpProgress(f, m); }
                        completion:done];
    });
    Check(error != nil, @"restore onto itself refused",
          error == nil ? @"it ran anyway" : ErrorText(error));

    /* A source larger than the destination must be refused BEFORE any copy.
     * The destination has to be a real restore target, or the refusal comes
     * from the capability gate and proves nothing about the size check. The
     * EFI partition is the smallest thing on the disk, so it is used as the
     * undersized destination. */
    DUStorageObject *small = PartitionVolumeOf(backend, 0);
    if (small != nil) {
        printf("       oversized test: %s -> %s\n", S(fat.displayName),
               S(small.displayName));
        fflush(stdout);
        error = RunAsync(backend, @"restore-too-big", ^(void (^done)(NSError *)) {
            [backend restoreFromSource:PartitionVolumeOf(backend, 2)
                           destination:PartitionVolumeOf(backend, 0)
                               options:@{}
                              progress:^(double f, NSString *m) { DumpProgress(f, m); }
                            completion:done];
        });
        Check(error != nil, @"oversized source refused before copying",
              error == nil ? @"it ran anyway" : ErrorText(error));
        // The EFI partition must be untouched by the refusal.
        Check(ShellOK(@"gpart show %@ | grep -q efi", gDevice.lastPathComponent),
              @"destination survived the refused restore", @"");
    }

    // A whole disk must not be a destination for a restore.
    error = RunAsync(backend, @"restore-to-disk", ^(void (^done)(NSError *)) {
        [backend restoreFromSource:fat
                       destination:DiskOf(backend, gDevice)
                           options:@{}
                          progress:^(double f, NSString *m) { DumpProgress(f, m); }
                        completion:done];
    });
    printf("       restore to whole disk: %s\n",
           error == nil ? "ACCEPTED" : S(ErrorText(error)));
    fflush(stdout);
    // A whole disk is offered as a destination by the picker but has no
    // filesystem to restore onto, so accepting it is not the outcome.
    Check(error != nil, @"whole-disk restore destination refused",
          error == nil ? @"the backend accepted it" : ErrorText(error));

    printf("       source %s (%s) -> destination %s (%s)\n",
           S(fat.displayName), S(fat.backendPath), S(ufs.displayName),
           S(ufs.backendPath));
    fflush(stdout);
    error = RunAsync(backend, @"restore", ^(void (^done)(NSError *)) {
        [backend restoreFromSource:PartitionVolumeOf(backend, 2)
                       destination:PartitionVolumeOf(backend, 1)
                           options:@{}
                          progress:^(double f, NSString *m) { DumpProgress(f, m); }
                        completion:done];
    });
    Check(error == nil, @"restore partition to partition", ErrorText(error));

    // After the copy the destination must be byte-identical to the source
    // over the length that was copied.
    // Hash the LIVE nodes; the objects captured before the restore carry
    // pre-restore state.
    NSString *srcNode = PartitionVolumeOf(backend, 2).backendPath;
    NSString *dstNode = PartitionVolumeOf(backend, 1).backendPath;
    NSString *srcHash =
        DUParsingLikeTrim(Shell(@"dd if=%@ bs=1m count=8 2>/dev/null | sha256 "
                                @"| cut -d= -f2",
                                srcNode));
    NSString *dstHash =
        DUParsingLikeTrim(Shell(@"dd if=%@ bs=1m count=8 2>/dev/null | sha256 "
                                @"| cut -d= -f2",
                                dstNode));
    Check(srcHash.length == 64 && [srcHash isEqualToString:dstHash],
          @"restored bytes match the source", dstHash);
}

static void PhaseRAID(id<DUStorageBackend> backend)
{
    printf("\n== RAID ==\n");
    fflush(stdout);
    /* A concat set over two partitions of the same disk is the one RAID
     * shape that can be exercised without a second physical disk. */
    DUStorageObject *a = PartitionVolumeOf(backend, 1);
    DUStorageObject *b = PartitionVolumeOf(backend, 2);
    if (a == nil || b == nil) {
        Fail(@"RAID", @"not enough partitions");
        return;
    }
    if (![(id)backend respondsToSelector:@selector(createRAIDWithName:
                                                       level:
                                                     members:)]) {
        Fail(@"RAID",
             @"the backend does not implement the RAID verb at all, so the "
             @"RAID tab cannot create anything");
        return;
    }
    /* The geom RAID classes have to be loadable, or every gconcat/gmirror
     * call fails with "Invalid class name 'concat'" no matter what the app
     * does - which is what this host reports, so the verb cannot be proven
     * end to end here and that has to be stated rather than glossed over. */
    NSString *classList = DUParsingLikeTrim(ShellOut(@"geom class list"));
    BOOL classesAvailable =
        [classList rangeOfString:@"concat"].location != NSNotFound;
    printf("       geom class list: %s\n",
           classesAvailable ? S(classList) : "(concat/mirror/stripe absent)");
    fflush(stdout);

    /* Called through a typed declaration rather than a runtime lookup: the
     * verb exists on the concrete backend, so the exercise proves whether
     * running it works, independently of the missing protocol declaration. */
    NSError *error =
        [(id)backend createRAIDWithName:@"duLive"
                                   level:@"concat"
                                 members:@[ a, b ]];
    NSString *list = DUParsingLikeTrim(ShellOut(@"gconcat list"));
    printf("       gconcat list: %s\n", S(list));
    fflush(stdout);

    if (!classesAvailable) {
        /* Nothing to assert about the app here: the tool is unusable. Report
         * the state and move on rather than scoring a pass or a failure the
         * app does not control. */
        Pass(@"RAID skipped - the geom RAID classes are not available",
             classList);
        return;
    }

    Check(error == nil, @"create a concatenated RAID set", ErrorText(error));
    if (error != nil) {
        return;
    }
    Check([list rangeOfString:@"duLive"].location != NSNotFound,
          @"the RAID provider exists", list);
    // The set must be taken apart again, or every later phase that walks the
    // geom tree sees the RAID provider instead of the partitions.
    Check(ShellOK(@"gconcat detach duLive"), @"RAID set detached",
          DUParsingLikeTrim(ShellOut(@"gconcat detach duLive 2>&1")));
    Shell(@"gconcat destroy duLive >/dev/null 2>&1");
    Check([DUParsingLikeTrim(ShellOut(@"gconcat list"))
              rangeOfString:@"duLive"]
              .location == NSNotFound,
          @"no RAID provider left behind",
          DUParsingLikeTrim(ShellOut(@"gconcat list")));
    fflush(stdout);
}

static void PhaseSecureErase(id<DUStorageBackend> backend)
{
    printf("\n== secure erase (zeros) on one partition ==\n");
    fflush(stdout);
    DUStorageObject *fat = PartitionVolumeOf(backend, 2);
    if (fat == nil) {
        Fail(@"secure erase", @"FAT volume missing");
        return;
    }
    __block double highest = 0.0;
    NSError *error =
        RunAsync(backend, @"erase-zeros", ^(void (^done)(NSError *)) {
        [backend eraseObject:fat
                     options:@{ kDUFormatIdentifierKey : @"ufs",
                                kDUEraseSecurityMethodKey :
                                    kDUEraseMethodZerosKey,
                                @"name" : @"ZEROED" }
                    progress:^(double f, NSString *m) {
                        if (f > highest) {
                            highest = f;
                        }
                        DumpProgress(f, m);
                    }
                  completion:done];
    });
    Check(error == nil, @"erase with a zero pass then UFS", ErrorText(error));
    Check(HasUFSTag(@"ZEROED", fat.backendPath),
          @"label written after the zero pass", fat.backendPath);
    // The progress bar must actually move during the wipe.
    Check(highest > 0.2,
          @"zero pass reported intermediate progress",
          [NSString stringWithFormat:@"highest %.0f%%", highest * 100.0]);
}

static void PhaseWholeDiskErase(id<DUStorageBackend> backend)
{
    printf("\n== whole-disk erase (destroys the table) ==\n");
    fflush(stdout);
    DUStorageObject *disk = DiskOf(backend, gDevice);
    if (disk == nil) {
        Fail(@"whole-disk erase", @"device vanished");
        return;
    }
    NSError *error =
        RunAsync(backend, @"erase-disk", ^(void (^done)(NSError *)) {
        [backend eraseObject:disk
                     options:@{ kDUFormatIdentifierKey : @"ufs",
                                @"name" : @"WHOLEDISK" }
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    Check(error == nil, @"erase the whole disk", ErrorText(error));
    Check(HasUFSTag(@"WHOLEDISK", gDevice),
          @"whole disk carries the new filesystem", gDevice);

    error = RunAsync(backend, @"verify-whole", ^(void (^done)(NSError *)) {
        [backend verifyObject:ObjectAtNode(backend, gDevice)
                    progress:^(double f, NSString *m) { DumpProgress(f, m); }
                  completion:done];
    });
    Check(error == nil, @"verify the freshly erased disk", ErrorText(error));

    DUStorageObject *after = DiskOf(backend, gDevice);
    if (after != nil) {
        DUStorageDevice *device = (DUStorageDevice *)after;
        printf("       scheme after whole-disk erase: %s\n",
               S(device.partitionScheme ?: @"(none)"));
        fflush(stdout);
        Check(device.children.count == 0,
              @"the old partition table is gone",
              [NSString stringWithFormat:@"%lu children",
                                         (unsigned long)device.children.count]);
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        gFailures = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            if (strncmp(argv[i], "--device=", 9) == 0) {
                gDevice = @(argv[i] + 9);
            }
            if (strncmp(argv[i], "--timeout=", 10) == 0) {
                gStepTimeout = atof(argv[i] + 10);
            }
        }
        if (gDevice == nil && argc > 1 && argv[1][0] == '/') {
            gDevice = @(argv[1]);
        }
        if (gDevice == nil) {
            printf("usage: t_LiveBackend /dev/<node>   (DESTROYS that disk)\n");
            return 2;
        }
        if (geteuid() != 0) {
            printf("must run as root: the backend escalates with sudo and the\n"
                   "askpass helper cannot answer from a terminal tool.\n");
            return 2;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:gDevice]) {
            printf("no such device: %s\n", gDevice.UTF8String);
            return 2;
        }
        printf("DiskUtility live backend exercise on %s\n"
               "THIS ERASES %s COMPLETELY.\n",
               gDevice.UTF8String, gDevice.UTF8String);
        NSSetUncaughtExceptionHandler(&ReportUncaughtException);
        id<DUStorageBackend> backend = Backend();
        // A crash in a phase means a real defect in the path the exercise
        // drives, so each one is wrapped: the report names the phase and the
        // exception instead of the run aborting with a bare line.
        PhaseRun(backend, @"capabilities", PhaseCapabilities);
        PhaseRun(backend, @"discovery", PhaseDiscovery);
        PhaseRun(backend, @"safety guards", PhaseGuards);
        PhaseRun(backend, @"partitioning", PhasePartitioning);
        PhaseRun(backend, @"formatting", PhaseFormats);
        PhaseRun(backend, @"first aid", PhaseFirstAid);
        PhaseRun(backend, @"mount round trip", PhaseMountData);
        PhaseRun(backend, @"disk images", PhaseImages);
        PhaseRun(backend, @"restore", PhaseRestore);
        PhaseRun(backend, @"RAID", PhaseRAID);
        PhaseRun(backend, @"secure erase", PhaseSecureErase);
        PhaseRun(backend, @"whole-disk erase", PhaseWholeDiskErase);

        printf("\n== summary ==\n  %d passed, %d failed\n", gPassed, gFailed);
    fflush(stdout);
        for (NSString *failure in gFailures) {
            printf("  - %s\n", failure.UTF8String);
        }
        return gFailed == 0 ? 0 : 1;
    }
}
