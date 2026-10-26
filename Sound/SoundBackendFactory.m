/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundBackendFactory.h"
#import "ALSABackend.h"
#ifndef __OpenBSD__
#import "OSSBackend.h"
#endif

id<SoundBackend> SoundBackendCreateDefault(void)
{
    id<SoundBackend> backend = nil;

#if defined(__FreeBSD__) || defined(__DragonFly__)
    /* OSS is the native sound system here. */
    backend = [[OSSBackend alloc] init];
    if ([backend isAvailable]) {
        return backend;
    }
    [backend release];
#endif

    backend = [[ALSABackend alloc] init];
    if ([backend isAvailable]) {
        return backend;
    }
    [backend release];

#if !defined(__FreeBSD__) && !defined(__DragonFly__) && !defined(__OpenBSD__)
    /* OSS4 installed on Linux or NetBSD's OSS emulation. */
    backend = [[OSSBackend alloc] init];
    if ([backend isAvailable]) {
        return backend;
    }
    [backend release];
#endif

    NSDebugLLog(@"gwcomp", @"SoundBackendCreateDefault: no sound backend available");
    return nil;
}
