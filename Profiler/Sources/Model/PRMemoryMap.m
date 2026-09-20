/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRMemoryMap.h"

NSString *PRMemoryKindName(PRMemoryKind kind)
{
    switch (kind) {
        case PRMemoryKindHeap: return @"Heap";
        case PRMemoryKindStack: return @"Stacks";
        case PRMemoryKindAnonymous: return @"Anonymous memory";
        case PRMemoryKindCode: return @"Program and libraries";
        case PRMemoryKindFile: return @"Mapped files";
        case PRMemoryKindShared: return @"Shared memory";
        case PRMemoryKindSystem: return @"Kernel provided";
        default: return @"Other";
    }
}

NSString *PRMemoryKindExplanation(PRMemoryKind kind)
{
    switch (kind) {
        case PRMemoryKindHeap:
            return @"What the program asked for with malloc and never gave "
                   @"back yet";
        case PRMemoryKindStack:
            return @"The call stacks of the program's threads";
        case PRMemoryKindAnonymous:
            return @"Memory mapped directly, often large buffers and thread "
                   @"stacks";
        case PRMemoryKindCode:
            return @"The program and the libraries it uses, shared with every "
                   @"other program that uses them";
        case PRMemoryKindFile:
            return @"Files read through memory, such as fonts and data";
        case PRMemoryKindShared:
            return @"Memory shared with other programs, such as images passed "
                   @"to the display";
        case PRMemoryKindSystem:
            return @"Provided by the kernel to every program";
        default:
            return @"";
    }
}

@implementation PRMemoryRegion
@synthesize name = _name;
@synthesize path = _path;
@synthesize kind = _kind;
@synthesize resident = _resident;
@synthesize privateBytes = _privateBytes;
@synthesize swap = _swap;
@synthesize mapped = _mapped;
@synthesize count = _count;

- (id)init
{
    self = [super init];
    if (self != nil)
        _count = 1;
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %llu resident", _name, _resident];
}
@end

@implementation PRMemoryMap

@synthesize regions = _regions;

+ (PRMemoryMap *)mapWithRegions:(NSArray *)regions
{
    PRMemoryMap *map = [[PRMemoryMap alloc] init];
    map->_regions = [regions copy];
    return map;
}

/* The path of a mapping says what it is for; the kernel names the ones that
   have no file of their own. */
+ (PRMemoryKind)kindForPath:(NSString *)path permissions:(NSString *)permissions
{
    if ([path length] == 0)
        return PRMemoryKindAnonymous;
    if ([path isEqualToString:@"[heap]"])
        return PRMemoryKindHeap;
    if ([path hasPrefix:@"[stack"])
        return PRMemoryKindStack;
    if ([path hasPrefix:@"[v"] || [path isEqualToString:@"[uprobes]"])
        return PRMemoryKindSystem;
    if ([path hasPrefix:@"[anon"])
        return PRMemoryKindAnonymous;
    if ([path hasPrefix:@"/SYSV"] || [path hasPrefix:@"/dev/shm"] ||
        [path hasPrefix:@"/memfd:"] || [path hasPrefix:@"/dev/dri"] ||
        [path hasPrefix:@"/drm"] || [path hasPrefix:@"/dev/nvidia"])
        return PRMemoryKindShared;
    if ([permissions rangeOfString:@"s"].location != NSNotFound)
        return PRMemoryKindShared;
    if ([permissions rangeOfString:@"x"].location != NSNotFound)
        return PRMemoryKindCode;
    return PRMemoryKindFile;
}

/* A mapping of a library appears several times, once per part of the file,
   and only their sum is worth looking at. */
+ (NSString *)nameForPath:(NSString *)path kind:(PRMemoryKind)kind
{
    if ([path length] == 0)
        return kind == PRMemoryKindStack ? @"[thread stack]" : @"[anonymous]";
    if ([path hasPrefix:@"["])
        return path;
    return [path lastPathComponent];
}

+ (unsigned long long)bytesFromLine:(NSString *)line
{
    NSArray *fields = [[line componentsSeparatedByCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]]
                       filteredArrayUsingPredicate:
                       [NSPredicate predicateWithFormat:@"length > 0"]];
    if ([fields count] < 2)
        return 0;
    /* Every one of these is reported in kilobytes. */
    return (unsigned long long)[[fields objectAtIndex:1] longLongValue] * 1024ULL;
}

+ (PRMemoryMap *)mapFromSmapsText:(NSString *)text
{
    NSMutableArray *regions = [NSMutableArray array];
    PRMemoryRegion *region = nil;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:
                           @"0123456789abcdefABCDEF"];

    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line length] == 0)
            continue;

        /* A mapping starts with its address range, everything after it
           describes that mapping. */
        NSRange dash = [line rangeOfString:@"-"];
        BOOL isHeader = dash.location != NSNotFound && dash.location > 0 &&
            [[line substringToIndex:dash.location]
             rangeOfCharacterFromSet:[hex invertedSet]].location == NSNotFound;

        if (isHeader) {
            NSArray *fields = [[line componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]]
                               filteredArrayUsingPredicate:
                               [NSPredicate predicateWithFormat:@"length > 0"]];
            if ([fields count] < 5) {
                region = nil;
                continue;
            }

            NSString *permissions = [fields objectAtIndex:1];
            NSString *path = [fields count] > 5 ?
                [[fields subarrayWithRange:NSMakeRange(5, [fields count] - 5)]
                 componentsJoinedByString:@" "] : @"";
            PRMemoryKind kind = [self kindForPath:path permissions:permissions];

            region = [[PRMemoryRegion alloc] init];
            [region setPath:path];
            [region setKind:kind];
            [region setName:[self nameForPath:path kind:kind]];
            [regions addObject:region];
            continue;
        }

        if (region == nil)
            continue;

        if ([line hasPrefix:@"Rss:"])
            [region setResident:[self bytesFromLine:line]];
        else if ([line hasPrefix:@"Private_Clean:"] ||
                 [line hasPrefix:@"Private_Dirty:"])
            [region setPrivateBytes:[region privateBytes] +
             [self bytesFromLine:line]];
        else if ([line hasPrefix:@"Swap:"])
            [region setSwap:[self bytesFromLine:line]];
        else if ([line hasPrefix:@"Size:"])
            [region setMapped:[self bytesFromLine:line]];
    }

    /* A library is mapped several times: its code once and its data again
       without the right to execute. Judged on its own, that data mapping
       would look like any other file read through memory, so what a file is
       used for is decided by the file, not by the single mapping. */
    NSMutableSet *executable = [NSMutableSet set];
    for (PRMemoryRegion *mapping in regions)
        if ([mapping kind] == PRMemoryKindCode && [[mapping path] length] > 0)
            [executable addObject:[mapping path]];
    for (PRMemoryRegion *mapping in regions)
        if ([mapping kind] == PRMemoryKindFile &&
            [executable containsObject:[mapping path]])
            [mapping setKind:PRMemoryKindCode];

    return [self mapWithRegions:regions];
}

- (unsigned long long)sumOfSelector:(SEL)selector
{
    unsigned long long sum = 0;
    for (PRMemoryRegion *region in _regions) {
        if (selector == @selector(resident))
            sum += [region resident];
        else if (selector == @selector(privateBytes))
            sum += [region privateBytes];
        else if (selector == @selector(swap))
            sum += [region swap];
        else
            sum += [region mapped];
    }
    return sum;
}

- (unsigned long long)resident { return [self sumOfSelector:@selector(resident)]; }
- (unsigned long long)privateBytes { return [self sumOfSelector:@selector(privateBytes)]; }
- (unsigned long long)swap { return [self sumOfSelector:@selector(swap)]; }
- (unsigned long long)mapped { return [self sumOfSelector:@selector(mapped)]; }

- (NSArray *)sortedRegions:(NSArray *)regions
{
    return [regions sortedArrayUsingComparator:
            ^NSComparisonResult(PRMemoryRegion *a, PRMemoryRegion *b) {
        if ([a resident] > [b resident]) return NSOrderedAscending;
        if ([a resident] < [b resident]) return NSOrderedDescending;
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];
}

- (NSArray *)groupedBy:(BOOL)byKind
{
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];

    for (PRMemoryRegion *region in _regions) {
        NSString *key = byKind ?
            [NSString stringWithFormat:@"%d", (int)[region kind]] :
            [NSString stringWithFormat:@"%d %@", (int)[region kind],
             [region name]];
        PRMemoryRegion *group = [groups objectForKey:key];

        if (group == nil) {
            group = [[PRMemoryRegion alloc] init];
            [group setKind:[region kind]];
            [group setName:byKind ? PRMemoryKindName([region kind]) :
             [region name]];
            [group setPath:byKind ? PRMemoryKindExplanation([region kind]) :
             [region path]];
            [group setCount:0];
            [groups setObject:group forKey:key];
        }

        [group setResident:[group resident] + [region resident]];
        [group setPrivateBytes:[group privateBytes] + [region privateBytes]];
        [group setSwap:[group swap] + [region swap]];
        [group setMapped:[group mapped] + [region mapped]];
        [group setCount:[group count] + 1];
    }

    return [self sortedRegions:[groups allValues]];
}

- (NSArray *)regionsByKind
{
    return [self groupedBy:YES];
}

- (NSArray *)regionsByName
{
    return [self groupedBy:NO];
}

@end
