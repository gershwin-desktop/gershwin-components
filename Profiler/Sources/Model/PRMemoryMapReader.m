/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRMemoryMapReader.h"
#import "PRMemoryMap.h"
#import "PRRecorder.h"

#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__) || \
    defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <unistd.h>
#endif

@implementation PRMemoryMapReader

+ (NSError *)errorWithMessage:(NSString *)message
{
    return [NSError errorWithDomain:PRErrorDomain
                               code:11
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#if defined(__linux__)

+ (BOOL)reportsResidentMemoryPerMapping
{
    return YES;
}

+ (PRMemoryMap *)mapForProcess:(pid_t)pid error:(NSError **)error
{
    NSString *path = [NSString stringWithFormat:@"/proc/%d/smaps", (int)pid];
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text == nil) {
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"This process does not let itself be looked at. Only "
                      @"your own processes report where their memory sits."];
        return nil;
    }
    return [PRMemoryMap mapFromSmapsText:text];
}

#elif defined(__FreeBSD__) || defined(__FreeBSD_kernel__) || \
      defined(__DragonFly__) || defined(__NetBSD__)

+ (BOOL)reportsResidentMemoryPerMapping
{
    return YES;
}

/* The kernel hands out one record per mapping, with the pages that are
   really there and the file the mapping came from. */
+ (PRMemoryMap *)mapForProcess:(pid_t)pid error:(NSError **)error
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_VMMAP, (int)pid };
    size_t size = 0;

    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"This process does not let itself be looked at. Only "
                      @"your own processes report where their memory sits."];
        return nil;
    }

    /* The kernel may need more room by the time it answers. */
    size = size * 4 / 3;
    char *buffer = malloc(size);
    if (buffer == NULL)
        return nil;

    if (sysctl(mib, 4, buffer, &size, NULL, 0) != 0) {
        free(buffer);
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"The system stopped telling where the memory sits."];
        return nil;
    }

    NSMutableArray *regions = [NSMutableArray array];
    unsigned long long pageSize = (unsigned long long)getpagesize();
    char *cursor = buffer;
    char *end = buffer + size;

    while (cursor < end) {
        struct kinfo_vmentry *entry = (struct kinfo_vmentry *)cursor;
        if (entry->kve_structsize == 0)
            break;

        NSString *path = entry->kve_path[0] != '\0' ?
            [NSString stringWithUTF8String:entry->kve_path] : @"";
        BOOL executable = (entry->kve_protection & KVME_PROT_EXEC) != 0;
        BOOL shared = (entry->kve_flags & KVME_FLAG_SUPER) == 0 &&
                      entry->kve_type == KVME_TYPE_DEFAULT &&
                      (entry->kve_flags & KVME_FLAG_NEEDS_COPY) == 0 &&
                      [path length] > 0;

        PRMemoryRegion *region = [[PRMemoryRegion alloc] init];
        [region setPath:path];
        [region setKind:[self kindForPath:path
                               executable:executable
                                   shared:shared
                                     type:entry->kve_type]];
        [region setName:[path length] > 0 ? [path lastPathComponent] :
         [self nameForType:entry->kve_type]];
        [region setResident:(unsigned long long)entry->kve_resident * pageSize];
        [region setPrivateBytes:(unsigned long long)
         entry->kve_private_resident * pageSize];
        [region setMapped:(unsigned long long)(entry->kve_end - entry->kve_start)];
        [regions addObject:region];

        cursor += entry->kve_structsize;
    }

    free(buffer);
    return [PRMemoryMap mapWithRegions:regions];
}

+ (NSString *)nameForType:(int)type
{
    switch (type) {
        case KVME_TYPE_SWAP: return @"[anonymous]";
        case KVME_TYPE_PHYS: return @"[device]";
        case KVME_TYPE_DEAD: return @"[gone]";
        default: return @"[anonymous]";
    }
}

+ (PRMemoryKind)kindForPath:(NSString *)path
                 executable:(BOOL)executable
                     shared:(BOOL)shared
                       type:(int)type
{
    if (type == KVME_TYPE_PHYS || type == KVME_TYPE_SG)
        return PRMemoryKindShared;
    if ([path length] == 0)
        return PRMemoryKindAnonymous;
    if (executable)
        return PRMemoryKindCode;
    if (shared)
        return PRMemoryKindShared;
    return PRMemoryKindFile;
}

#elif defined(__OpenBSD__)

/* OpenBSD reports which parts of the address space are claimed, but not how
   much of each is really in RAM, so only the mapped size can be shown. */
+ (BOOL)reportsResidentMemoryPerMapping
{
    return NO;
}

+ (PRMemoryMap *)mapForProcess:(pid_t)pid error:(NSError **)error
{
    int mib[3] = { CTL_KERN, KERN_PROC_VMMAP, (int)pid };
    size_t size = 0;

    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"This process does not let itself be looked at. Only "
                      @"your own processes report where their memory sits."];
        return nil;
    }

    size = size * 4 / 3;
    char *buffer = malloc(size);
    if (buffer == NULL)
        return nil;

    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
        free(buffer);
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"The system stopped telling where the memory sits."];
        return nil;
    }

    NSMutableArray *regions = [NSMutableArray array];
    size_t count = size / sizeof(struct kinfo_vmentry);

    for (size_t i = 0; i < count; i++) {
        struct kinfo_vmentry *entry =
            &((struct kinfo_vmentry *)buffer)[i];
        BOOL executable = (entry->kve_protection & KVE_PROT_EXEC) != 0;

        PRMemoryRegion *region = [[PRMemoryRegion alloc] init];
        [region setPath:@""];
        [region setKind:executable ? PRMemoryKindCode : PRMemoryKindAnonymous];
        [region setName:executable ? @"[code]" : @"[anonymous]"];
        [region setMapped:(unsigned long long)
         (entry->kve_end - entry->kve_start)];
        [regions addObject:region];
    }

    free(buffer);
    return [PRMemoryMap mapWithRegions:regions];
}

#else

+ (BOOL)reportsResidentMemoryPerMapping
{
    return NO;
}

+ (PRMemoryMap *)mapForProcess:(pid_t)pid error:(NSError **)error
{
    (void)pid;
    if (error != NULL)
        *error = [self errorWithMessage:
                  @"This system does not say where a program's memory sits."];
    return nil;
}

#endif

@end
