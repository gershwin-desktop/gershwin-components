/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BacklightBackend.h"
#if defined(__linux__)
#import "SysfsBacklightBackend.h"
#elif defined(__FreeBSD__)
#import "FreeBSDBacklightBackend.h"
#elif defined(__OpenBSD__) || defined(__NetBSD__)
#import "WsconsBacklightBackend.h"
#endif

id<BacklightBackend> BacklightBackendCreateDefault(void)
{
#if defined(__linux__)
    return [[SysfsBacklightBackend alloc] init];
#elif defined(__FreeBSD__)
    return [[FreeBSDBacklightBackend alloc] init];
#elif defined(__OpenBSD__) || defined(__NetBSD__)
    return [[WsconsBacklightBackend alloc] init];
#else
    return nil;
#endif
}
