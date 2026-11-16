/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "PRAllocationTrace.h"

/* Shortened from the recording that found Menu re-decoding every
   application icon: two samples from one place and one from another. */
static NSString *perfScript(void)
{
    return
    @"Menu 26589 [007] 25341.845876: syscalls:sys_enter_mmap: addr: 0x00000000, len: 0x00600000, prot: 0x00000003\n"
    @"\t    7f1dde25ce22 __GI___mmap64+0x22 (inlined)\n"
    @"\t    7f1dde1f09ca sysmalloc+0x1da (/usr/lib/x86_64-linux-gnu/libc.so.6)\n"
    @"\t    7f1dde91c6bf NSZoneMalloc+0x1f (/System/Library/Libraries/libgnustep-base.so.1.31.1)\n"
    @"\t    7f1ddee36507 _i_NSBitmapImageRep_PNG__initBitmapFromPNG_+0x4c7 (/System/Library/Libraries/libgnustep-gui.so.0.32.0)\n"
    @"\t    55d7d4b6a67e _i_AppMenuWidget__addMenuItemsFromTree_toMenu_+0x8be (/System/Library/CoreServices/Applications/Menu.app/Menu)\n"
    @"\n"
    @"Menu 26589 [007] 25341.914401: syscalls:sys_enter_mmap: addr: 0x00000000, len: 0x00301000, prot: 0x00000003\n"
    @"\t    7f1dde25ce22 __GI___mmap64+0x22 (inlined)\n"
    @"\t    7f1dde1f09ca sysmalloc+0x1da (/usr/lib/x86_64-linux-gnu/libc.so.6)\n"
    @"\t    7f1dde91c6bf NSZoneMalloc+0x1f (/System/Library/Libraries/libgnustep-base.so.1.31.1)\n"
    @"\t    7f1ddee36507 _i_NSBitmapImageRep_PNG__initBitmapFromPNG_+0x4c7 (/System/Library/Libraries/libgnustep-gui.so.0.32.0)\n"
    @"\t    55d7d4b6a67e _i_AppMenuWidget__addMenuItemsFromTree_toMenu_+0x8be (/System/Library/CoreServices/Applications/Menu.app/Menu)\n"
    @"\n"
    @"Menu 26589 [002] 25342.100000: syscalls:sys_enter_mmap: addr: 0x00000000, len: 0x00100000, prot: 0x00000003\n"
    @"\t    7f1dde25ce22 __GI___mmap64+0x22 (inlined)\n"
    @"\t    7f1ddeec1b6c _i_NSMenu__update+0x2c (/System/Library/Libraries/libgnustep-gui.so.0.32.0)\n"
    @"\n";
}

int main(void)
{
    @autoreleasepool {
        START_SET("Large allocations")

        NSArray *sites = [PRAllocationTrace sitesFromPerfScript:perfScript()];

        PASS([sites count] == 2, "the same call path is one site, not two");

        PRAllocationSite *worst = [sites objectAtIndex:0];
        PASS([worst count] == 2, "and it says how often it was seen");
        PASS([worst byteCount] == 0x600000 + 0x301000,
             "the sizes of a call path are added up");
        PRAllocationSite *lighter = [sites objectAtIndex:1];
        PASS([lighter byteCount] == 0x100000,
             "the lighter site comes second");

        /* The reader wants the code that asked for the memory, not the
           allocator it went through. */
        NSArray *telling = [worst tellingFrames];
        PASS_EQUAL([telling objectAtIndex:0],
                   @"_i_NSBitmapImageRep_PNG__initBitmapFromPNG_ (libgnustep-gui.so.0.32.0)",
                   "the allocator's own frames are dropped");
        PASS([telling count] == 2, "what is left is the program's own path");
        PASS([[worst frames] count] == 5, "while the whole stack is kept");

        /* A stack of nothing but allocator frames still says something. */
        PASS([[lighter tellingFrames] count] == 1,
             "a stack that is only the allocator keeps its one frame");

        PASS([[PRAllocationTrace sitesFromPerfScript:@""] count] == 0,
             "nothing in, nothing out");
        PASS([[PRAllocationTrace sitesFromPerfScript:
               @"Menu 1 [0] 1: syscalls:sys_enter_mmap: len: 0x1000\n"] count] == 0,
             "a sample without a stack is not a site");

        END_SET("Large allocations")
    }
    return 0;
}
