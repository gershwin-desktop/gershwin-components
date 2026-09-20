/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRAllocationTrace.h"
#import "PRRecorder.h"
#import "PRPrivilegedTask.h"

@implementation PRAllocationSite

@synthesize frames = _frames;
@synthesize byteCount = _byteCount;
@synthesize count = _count;

/* Every large allocation goes through the same handful of allocator
   functions; the first frame above them is the one worth reading. */
+ (NSSet *)allocatorFrames
{
    static NSSet *names = nil;
    if (names == nil)
        names = [[NSSet alloc] initWithObjects:
                 @"__GI___mmap64", @"mmap", @"mmap64", @"sysmalloc",
                 @"sysmalloc_mmap", @"_int_malloc", @"__GI___libc_malloc",
                 @"__libc_malloc", @"malloc", @"calloc", @"realloc",
                 @"NSZoneMalloc", @"NSZoneRealloc", @"NSZoneCalloc",
                 @"GSIArrayGrow", @"objc_malloc", nil];
    return names;
}

- (NSArray *)tellingFrames
{
    NSSet *allocator = [PRAllocationSite allocatorFrames];
    NSUInteger first = 0;

    while (first < [_frames count]) {
        NSString *frame = [_frames objectAtIndex:first];
        NSString *name = [[frame componentsSeparatedByString:@" "] firstObject];
        if (![allocator containsObject:name])
            break;
        first++;
    }
    if (first >= [_frames count])
        return _frames;
    return [_frames subarrayWithRange:NSMakeRange(first, [_frames count] - first)];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%llu bytes in %lu at %@", _byteCount,
            (unsigned long)_count, [[self tellingFrames] firstObject]];
}

@end

@implementation PRAllocationTrace

/* "        7f1d..e22 -[NSImage initWithContentsOfFile:]+0x3a (/path/lib.so)"
   becomes "-[NSImage initWithContentsOfFile:] (lib.so)": the address says
   nothing to a reader and the offset even less. */
+ (NSString *)frameFromLine:(NSString *)line
{
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    NSRange space = [trimmed rangeOfString:@" "];
    if (space.location == NSNotFound)
        return nil;

    NSString *rest = [trimmed substringFromIndex:NSMaxRange(space)];
    NSString *symbol = rest;
    NSString *module = nil;

    NSRange bracket = [rest rangeOfString:@" (" options:NSBackwardsSearch];
    if (bracket.location != NSNotFound) {
        symbol = [rest substringToIndex:bracket.location];
        module = [rest substringFromIndex:NSMaxRange(bracket)];
        if ([module hasSuffix:@")"])
            module = [module substringToIndex:[module length] - 1];
        module = [module lastPathComponent];
    }

    NSRange plus = [symbol rangeOfString:@"+0x" options:NSBackwardsSearch];
    if (plus.location != NSNotFound)
        symbol = [symbol substringToIndex:plus.location];

    if ([symbol length] == 0)
        return nil;
    if ([module length] == 0 || [module isEqualToString:@"inlined"])
        return symbol;
    return [NSString stringWithFormat:@"%@ (%@)", symbol, module];
}

+ (unsigned long long)lengthFromHeader:(NSString *)line
{
    NSRange marker = [line rangeOfString:@"len: "];
    if (marker.location == NSNotFound)
        return 0;

    NSString *rest = [line substringFromIndex:NSMaxRange(marker)];
    NSScanner *scanner = [NSScanner scannerWithString:rest];
    unsigned long long value = 0;

    if ([rest hasPrefix:@"0x"]) {
        [scanner setScanLocation:2];
        if (![scanner scanHexLongLong:&value])
            return 0;
        return value;
    }
    long long decimal = 0;
    if (![scanner scanLongLong:&decimal])
        return 0;
    return (unsigned long long)decimal;
}

+ (NSArray *)sitesFromPerfScript:(NSString *)text
{
    NSMutableDictionary *sites = [NSMutableDictionary dictionary];
    NSMutableArray *frames = nil;
    unsigned long long pending = 0;

    /* A sample is a header line naming the size, then its call stack, then
       an empty line. */
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        BOOL isHeader = [line rangeOfString:@"sys_enter_mmap"].location != NSNotFound
            || [line rangeOfString:@"len: "].location != NSNotFound;
        BOOL isFrame = [line length] > 0 &&
            ([line hasPrefix:@"\t"] || [line hasPrefix:@"    "]);

        if (isHeader && !isFrame) {
            if (frames != nil)
                [self addFrames:frames byteCount:pending toSites:sites];
            pending = [self lengthFromHeader:line];
            frames = [NSMutableArray array];
            continue;
        }

        if ([[line stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]] length] == 0) {
            if (frames != nil)
                [self addFrames:frames byteCount:pending toSites:sites];
            frames = nil;
            pending = 0;
            continue;
        }

        if (isFrame && frames != nil) {
            NSString *frame = [self frameFromLine:line];
            if (frame != nil)
                [frames addObject:frame];
        }
    }
    if (frames != nil)
        [self addFrames:frames byteCount:pending toSites:sites];

    return [[sites allValues] sortedArrayUsingComparator:
            ^NSComparisonResult(PRAllocationSite *a, PRAllocationSite *b) {
        if ([a byteCount] > [b byteCount]) return NSOrderedAscending;
        if ([a byteCount] < [b byteCount]) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

+ (void)addFrames:(NSArray *)frames
            byteCount:(unsigned long long)bytes
          toSites:(NSMutableDictionary *)sites
{
    if ([frames count] == 0 || bytes == 0)
        return;

    NSString *key = [frames componentsJoinedByString:@"\n"];
    PRAllocationSite *site = [sites objectForKey:key];

    if (site == nil) {
        site = [[PRAllocationSite alloc] init];
        [site setFrames:frames];
        [sites setObject:site forKey:key];
    }
    [site setByteCount:[site byteCount] + bytes];
    [site setCount:[site count] + 1];
}

+ (NSError *)errorWithMessage:(NSString *)message
{
    return [NSError errorWithDomain:PRErrorDomain
                               code:12
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (NSArray *)sitesForProcess:(pid_t)pid
                     minimum:(unsigned long long)minimumBytes
                     seconds:(NSTimeInterval)seconds
                       error:(NSError **)error
{
    NSString *perf = [PRToolLocator pathForTool:@"perf"];
    if (perf == nil) {
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"perf is not installed, so large allocations cannot "
                      @"be traced."];
        return nil;
    }
    if (kill(pid, 0) != 0) {
        if (error != NULL)
            *error = [self errorWithMessage:
                      [NSString stringWithFormat:@"There is no process %d.",
                       (int)pid]];
        return nil;
    }

    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"PRAllocations-%d-%.0f",
                            (int)getpid(),
                            [NSDate timeIntervalSinceReferenceDate]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *data = [directory stringByAppendingPathComponent:@"perf.data"];

    /* The kernel reports every mapping the process asks for; the filter
       keeps the big ones, which is what makes this cheap enough to leave
       running on a desktop. */
    NSArray *recordArguments = @[@"record",
                                 @"-e", @"syscalls:sys_enter_mmap",
                                 @"--filter", [NSString stringWithFormat:
                                               @"len > %llu", minimumBytes],
                                 @"--call-graph", @"dwarf,16384",
                                 @"-p", [NSString stringWithFormat:@"%d", (int)pid],
                                 @"-o", data,
                                 @"--", @"sleep",
                                 [NSString stringWithFormat:@"%.0f", seconds]];

    if ([PRPrivilegedTask runTool:perf arguments:recordArguments elevated:YES] != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        if (error != NULL)
            *error = [self errorWithMessage:
                      @"perf could not watch that process. Tracing another "
                      @"program needs the rights to do so."];
        return nil;
    }

    NSString *script = [directory stringByAppendingPathComponent:@"perf.script"];
    NSString *shell = [NSString stringWithFormat:@"%@ script -i %@ > %@",
                       perf, data, script];
    if ([PRPrivilegedTask runTool:@"/bin/sh"
                        arguments:@[@"-c", shell]
                         elevated:YES] != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        if (error != NULL)
            *error = [self errorWithMessage:@"The recording could not be read."];
        return nil;
    }

    NSString *text = [NSString stringWithContentsOfFile:script
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];

    if (text == nil) {
        if (error != NULL)
            *error = [self errorWithMessage:@"The recording could not be read."];
        return nil;
    }
    return [self sitesFromPerfScript:text];
}

@end
