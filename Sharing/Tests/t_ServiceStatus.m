/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The command the helper runs on FreeBSD to ask rc.d whether a daemon runs.
 * It must be onestatus: plain status exits 1 for a running daemon whose
 * rcvar is not YES. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#define main sharing_helper_main
#include "../sharing-helper.c"
#undef main

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("rc.d status command")
    {
        char buf[256];
        PASS(rcd_status_command(buf, sizeof(buf), "sshd") == 0, "fits");
        PASS_EQUAL([NSString stringWithUTF8String:buf],
                   @"/usr/sbin/service sshd onestatus >/dev/null 2>&1",
                   "asks onestatus, not status");
        char tiny[8];
        PASS(rcd_status_command(tiny, sizeof(tiny), "sshd") != 0,
             "truncation is an error");
    }
    END_SET("rc.d status command")

    [arp release];
    return 0;
}
