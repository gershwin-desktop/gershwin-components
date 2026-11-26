/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "ObjectTesting.h"
#import "PRObjCDemangler.h"
#import "PRSymbol.h"

static NSString *demangle(NSString *raw)
{
    return [PRObjCDemangler demangle:raw className:NULL];
}

int main(void)
{
    @autoreleasepool {
        START_SET("Objective-C symbol demangling")

        PASS_EQUAL(demangle(@"_i_NSRunLoop__acceptInputForMode_beforeDate_"),
                   @"-[NSRunLoop acceptInputForMode:beforeDate:]",
                   "instance method without category");

        PASS_EQUAL(demangle(@"_c_NSString__stringWithFormat_"),
                   @"+[NSString stringWithFormat:]",
                   "class method");

        PASS_EQUAL(demangle(@"_i_NSRunLoop_OPENSTEP_performSelector_target_argument_order_modes_"),
                   @"-[NSRunLoop(OPENSTEP) performSelector:target:argument:order:modes:]",
                   "method in a category");

        PASS_EQUAL(demangle(@"_i_GSRunLoopCtxt__pollUntil_within_"),
                   @"-[GSRunLoopCtxt pollUntil:within:]",
                   "two argument selector");

        PASS_EQUAL(demangle(@"_i_NSView__dealloc"),
                   @"-[NSView dealloc]",
                   "selector without arguments");

        PASS_EQUAL(demangle(@"_i_NSWindow___initDefaults"),
                   @"-[NSWindow _initDefaults]",
                   "selector starting with an underscore keeps it");

        PASS_EQUAL(demangle(@"objc_msgSend"), @"objc_msgSend",
                   "plain C function is unchanged");
        PASS_EQUAL(demangle(@"_int_malloc"), @"_int_malloc",
                   "C function starting with an underscore is unchanged");
        PASS_EQUAL(demangle(@"[unknown]"), @"[unknown]",
                   "unresolved frame is unchanged");

        NSString *className = nil;
        [PRObjCDemangler demangle:@"_i_NSRunLoop_OPENSTEP_performSelector_"
                        className:&className];
        PASS_EQUAL(className, @"NSRunLoop", "class name is reported");

        [PRObjCDemangler demangle:@"malloc" className:&className];
        PASS(className == nil, "no class name for a C function");

        END_SET("Objective-C symbol demangling")

        START_SET("Symbol")

        PRSymbol *symbol = [[PRSymbol alloc]
                            initWithIndex:3
                            rawName:@"_i_NSView__drawRect_"
                            modulePath:@"/System/Library/Libraries/libgnustep-gui.so.0.32.0 (deleted)"];
        PASS_EQUAL([symbol displayName], @"-[NSView drawRect:]", "display name");
        PASS_EQUAL([symbol moduleName], @"libgnustep-gui.so.0.32.0",
                   "deleted marker is stripped from the module name");
        PASS_EQUAL([symbol className], @"NSView", "class of the symbol");
        PASS([symbol isKernel] == NO, "user space symbol");

        PRSymbol *kernel = [[PRSymbol alloc] initWithIndex:4
                                                   rawName:@"do_syscall_64"
                                                modulePath:@"[kernel.kallsyms]"];
        PASS([kernel isKernel] == YES, "kernel symbol is recognised");

        END_SET("Symbol")
    }
    return 0;
}
