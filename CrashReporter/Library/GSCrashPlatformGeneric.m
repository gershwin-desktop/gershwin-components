/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashPlatform.h"
#import "GSCrashConstants.h"
#import <sys/resource.h>

#if defined(__linux__)
@interface GSCrashPlatformLinux : NSObject <GSCrashPlatform>
@end
#endif
#import <sys/utsname.h>
#import <unistd.h>

/*
 * Generic platform: degrades gracefully. Used directly on unknown systems and
 * as the base class for the BSD subclasses, which override OS-specific probing
 * (kern.corefile via sysctl) while keeping the same contract.
 */
@interface GSCrashPlatformGeneric : NSObject <GSCrashPlatform>
@end

@implementation GSCrashPlatformGeneric

- (NSString *)platformName
{
    return GSCrashOSName();
}

- (BOOL)isCoreDumpingEnabled
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_CORE, &rl) != 0)
        return NO;
    return rl.rlim_cur > 0;
}

- (NSString *)coreDumpLocation
{
    return nil; /* unknown without OS-specific probing */
}

- (NSString *)existingCrashCollector
{
    return @"none";
}

- (BOOL)saveCoreConfiguration:(NSError **)error
{
    return YES;
}

- (BOOL)restoreCoreConfiguration:(NSError **)error
{
    return YES;
}

- (BOOL)configureCoreDumpsToDirectory:(NSString *)directory error:(NSError **)error
{
    /*
     * Without OS-specific privileged hooks we can at least raise the core-size
     * limit for the daemon and any process it spawns. A real BSD integration
     * would set kern.corefile via a privileged helper (see subclasses).
     */
    struct rlimit rl;
    rl.rlim_cur = RLIM_INFINITY;
    rl.rlim_max = RLIM_INFINITY;
    setrlimit(RLIMIT_CORE, &rl);
    return YES;
}

- (BOOL)installCrashMonitor:(NSError **)error
{
    return YES;
}

- (BOOL)startCrashService:(NSError **)error
{
    return YES;
}

@end

#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>

static NSString *GSCrashSysctlString(const char *name)
{
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0)
        return nil;
    char *buf = malloc(len);
    if (buf == NULL)
        return nil;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
    {
        free(buf);
        return nil;
    }
    NSString *s = [[NSString alloc] initWithBytes:buf
                                           length:len - 1
                                         encoding:NSUTF8StringEncoding];
    free(buf);
    return s;
}
#endif

#if defined(__FreeBSD__)
@interface GSCrashPlatformFreeBSD : GSCrashPlatformGeneric
@end
@implementation GSCrashPlatformFreeBSD
- (NSString *)platformName { return @"FreeBSD"; }
- (NSString *)coreDumpLocation
{
    NSString *cf = GSCrashSysctlString("kern.corefile");
    if (cf == nil)
        return nil;
    return [cf stringByDeletingLastPathComponent];
}
@end
#endif

#if defined(__OpenBSD__)
@interface GSCrashPlatformOpenBSD : GSCrashPlatformGeneric
@end
@implementation GSCrashPlatformOpenBSD
- (NSString *)platformName { return @"OpenBSD"; }
- (NSString *)coreDumpLocation
{
    NSString *cf = GSCrashSysctlString("kern.corefile");
    return [cf stringByDeletingLastPathComponent];
}
@end
#endif

#if defined(__NetBSD__)
@interface GSCrashPlatformNetBSD : GSCrashPlatformGeneric
@end
@implementation GSCrashPlatformNetBSD
- (NSString *)platformName { return @"NetBSD"; }
- (NSString *)coreDumpLocation
{
    NSString *cf = GSCrashSysctlString("kern.corefile");
    return [cf stringByDeletingLastPathComponent];
}
@end
#endif

id<GSCrashPlatform> GSCrashPlatformForCurrentOS(void)
{
    NSString *os = GSCrashOSName();
#if defined(__linux__)
    if ([os isEqualToString:@"Linux"])
        return [[GSCrashPlatformLinux alloc] init];
#endif
#if defined(__FreeBSD__)
    if ([os isEqualToString:@"FreeBSD"])
        return [[GSCrashPlatformFreeBSD alloc] init];
#endif
#if defined(__OpenBSD__)
    if ([os isEqualToString:@"OpenBSD"])
        return [[GSCrashPlatformOpenBSD alloc] init];
#endif
#if defined(__NetBSD__)
    if ([os isEqualToString:@"NetBSD"])
        return [[GSCrashPlatformNetBSD alloc] init];
#endif
    return [[GSCrashPlatformGeneric alloc] init];
}
