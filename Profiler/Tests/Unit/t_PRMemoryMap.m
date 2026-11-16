/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "PRMemoryMap.h"

static NSString *smaps(void)
{
    /* Shortened to the lines that are read, in the order the kernel writes
       them: the program's code, one of its libraries twice, the heap, an
       anonymous mapping, a shared one and a kernel provided page. */
    return
    @"55ed730ab000-55ed730b2000 r-xp 00002000 103:02 15335872   /usr/bin/demo\n"
    @"Size:                 28 kB\n"
    @"Rss:                  20 kB\n"
    @"Private_Clean:         4 kB\n"
    @"Private_Dirty:         0 kB\n"
    @"Swap:                  0 kB\n"
    @"7f00000000-7f00010000 r-xp 00000000 103:02 1  /System/Library/Libraries/libgnustep-base.so.1.31.1\n"
    @"Size:                 64 kB\n"
    @"Rss:                  40 kB\n"
    @"Private_Clean:         8 kB\n"
    @"Private_Dirty:         2 kB\n"
    @"Swap:                  0 kB\n"
    @"7f00010000-7f00020000 rw-p 00010000 103:02 1  /System/Library/Libraries/libgnustep-base.so.1.31.1\n"
    @"Size:                 64 kB\n"
    @"Rss:                  16 kB\n"
    @"Private_Clean:         0 kB\n"
    @"Private_Dirty:        16 kB\n"
    @"Swap:                  4 kB\n"
    @"55ed74000000-55ed78000000 rw-p 00000000 00:00 0   [heap]\n"
    @"Size:              65536 kB\n"
    @"Rss:                1024 kB\n"
    @"Private_Clean:         0 kB\n"
    @"Private_Dirty:      1024 kB\n"
    @"Swap:                 64 kB\n"
    @"7f10000000-7f10100000 rw-p 00000000 00:00 0 \n"
    @"Size:               1024 kB\n"
    @"Rss:                 512 kB\n"
    @"Private_Clean:         0 kB\n"
    @"Private_Dirty:       512 kB\n"
    @"Swap:                  0 kB\n"
    @"7f20000000-7f20040000 rw-s 00000000 00:05 12   /SYSV00000000 (deleted)\n"
    @"Size:                256 kB\n"
    @"Rss:                 256 kB\n"
    @"Private_Clean:         0 kB\n"
    @"Private_Dirty:         0 kB\n"
    @"Swap:                  0 kB\n"
    @"7ffd00000000-7ffd00001000 r--p 00000000 00:00 0  [vvar]\n"
    @"Size:                  4 kB\n"
    @"Rss:                   4 kB\n"
    @"Private_Clean:         0 kB\n"
    @"Private_Dirty:         0 kB\n"
    @"Swap:                  0 kB\n";
}

static PRMemoryRegion *named(NSArray *rows, NSString *name)
{
    for (PRMemoryRegion *row in rows)
        if ([[row name] isEqualToString:name])
            return row;
    return nil;
}

int main(void)
{
    @autoreleasepool {
        START_SET("Memory map")

        PRMemoryMap *map = [PRMemoryMap mapFromSmapsText:smaps()];

        PASS([[map regions] count] == 7, "every mapping is read");
        PASS([map resident] == 1872ULL * 1024, "resident memory is added up");
        PASS([map swap] == 68ULL * 1024, "so is what went to swap");
        PASS([map mapped] == 66976ULL * 1024,
             "and the address space the program claimed");

        NSArray *kinds = [map regionsByKind];
        PASS_EQUAL([[kinds objectAtIndex:0] name], @"Heap",
                   "the heaviest kind comes first");
        PASS([[kinds objectAtIndex:0] resident] == 1024ULL * 1024,
             "with everything of that kind added up");
        PASS([named(kinds, @"Program and libraries") resident] == 76ULL * 1024,
             "executable mappings count as code");
        PASS([named(kinds, @"Program and libraries") count] == 3,
             "and say how many mappings they are");
        PASS([named(kinds, @"Shared memory") resident] == 256ULL * 1024,
             "a shared mapping is not the program's own memory");
        PASS([named(kinds, @"Anonymous memory") resident] == 512ULL * 1024,
             "a mapping without a file is anonymous");
        PASS([named(kinds, @"Kernel provided") resident] == 4ULL * 1024,
             "and the kernel's own pages are told apart");

        /* Private memory is what would really be freed. */
        PASS([named(kinds, @"Heap") privateBytes] == 1024ULL * 1024,
             "the heap is the program's own");
        PASS([named(kinds, @"Shared memory") privateBytes] == 0,
             "shared memory is nobody's own");

        NSArray *names = [map regionsByName];
        PRMemoryRegion *base = named(names, @"libgnustep-base.so.1.31.1");
        PASS(base != nil, "a library is named by its file");
        PASS([base resident] == 56ULL * 1024,
             "and its mappings are added up into one row");
        PASS([base count] == 2, "which says how many they were");
        PASS([base swap] == 4ULL * 1024, "and what of it went to swap");

        END_SET("Memory map")
    }
    return 0;
}
