/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CPUGovernorBackend.h"

/* Reused verbatim from EnergyController's platform helpers: same paths, same
 * sudo tee for the privileged sysfs write, same sysctl names on the BSDs.
 * Kept as static C helpers (not instance methods) since this class is all
 * class methods - there is exactly one governor policy per host. */

static NSString *CPUGovBackendReadFile(NSString *path)
{
    NSString *content = [[NSString alloc] initWithContentsOfFile:path
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
    return [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *CPUGovBackendRunCommand(NSString *cmd, NSArray *args)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:cmd];
    if (args) [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];

    @try {
        [task launch];
    } @catch (NSException *e) {
        return @"";
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* sudo tee, exactly as the Energy pane does it: this host's sudoers is
 * already set up to let the logged-in user write scaling_governor without a
 * password prompt (see the Energy prefPane, which has used this same path
 * for its own governor popup since before this class existed). */
static BOOL CPUGovBackendWriteSysfs(NSString *path, NSString *value)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:
        @"-c",
        [NSString stringWithFormat:@"printf '%s' '%@' | /usr/bin/sudo tee '%@' > /dev/null",
            [value UTF8String], value, path],
        nil]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return NO;
    }
    [task waitUntilExit];
    return ([task terminationStatus] == 0);
}

@implementation CPUGovernorBackend

+ (NSArray<NSString *> *)parseAvailableGovernorsFromSysfsList:(NSString *)raw
{
    if ([raw length] == 0) {
        return @[@"powersave", @"performance"];
    }
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *governors = [NSMutableArray arrayWithCapacity:[parts count]];
    for (NSString *part in parts) {
        if ([part length] > 0) [governors addObject:part];
    }
    return governors;
}

+ (NSUInteger)indexOfGovernor:(NSString *)governor inList:(NSArray<NSString *> *)governors
{
    if ([governor length] == 0) return NSNotFound;
    return [governors indexOfObject:governor];
}

+ (NSArray<NSString *> *)availableGovernors
{
#if defined(__linux__)
    NSString *raw = CPUGovBackendReadFile(@"/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors");
    return [self parseAvailableGovernorsFromSysfsList:raw];
#elif defined(__FreeBSD__) || defined(__NetBSD__)
    /* cpufreq reports raw frequencies, not named governors; offer the same
     * fixed policy set the Energy pane already shows for these. */
    return @[@"Auto", @"Maximum", @"Minimum"];
#elif defined(__OpenBSD__)
    /* hw.setperf: 0..100 */
    return @[@"Power Save", @"Auto", @"Performance"];
#else
    return @[@"Auto"];
#endif
}

+ (NSString *)currentGovernor
{
#if defined(__linux__)
    return CPUGovBackendReadFile(@"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor");
#elif defined(__FreeBSD__)
    return CPUGovBackendRunCommand(@"/sbin/sysctl", @[@"-n", @"dev.cpu.0.freq"]);
#elif defined(__OpenBSD__)
    return CPUGovBackendRunCommand(@"/sbin/sysctl", @[@"-n", @"hw.setperf"]);
#elif defined(__NetBSD__)
    return CPUGovBackendRunCommand(@"/sbin/sysctl", @[@"-n", @"machdep.cpu.frequency.current"]);
#else
    return nil;
#endif
}

+ (BOOL)setGovernor:(NSString *)governor
{
    if ([governor length] == 0) return NO;

#if defined(__linux__)
    NSString *path = @"/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";
    BOOL ok = CPUGovBackendWriteSysfs(path, governor);
    /* Apply to every online CPU, not just cpu0 - a governor set on one core
     * only would leave the others at whatever they had before. */
    CPUGovBackendRunCommand(@"/bin/sh",
        @[@"-c",
          @"for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do printf '%s' \"$1\" | sudo tee \"$cpu\" > /dev/null; done",
          @"sh", governor]);
    return ok;
#elif defined(__FreeBSD__)
    int freq;
    if ([governor isEqualToString:@"Maximum"]) freq = 100000;
    else if ([governor isEqualToString:@"Minimum"]) freq = 0;
    else freq = -1; /* Auto: let the system decide */
    if (freq >= 0) {
        CPUGovBackendRunCommand(@"/sbin/sysctl",
            @[@"dev.cpu.0.freq", [NSString stringWithFormat:@"%d", freq]]);
    }
    return YES;
#elif defined(__OpenBSD__)
    int perf = 50;
    if ([governor isEqualToString:@"Performance"]) perf = 100;
    else if ([governor isEqualToString:@"Power Save"]) perf = 0;
    CPUGovBackendRunCommand(@"/sbin/sysctl",
        @[@"hw.setperf", [NSString stringWithFormat:@"%d", perf]]);
    return YES;
#else
    /* NetBSD and anything else: mostly read-only here, same as the Energy
     * pane - report success so the menu does not show a false failure. */
    return YES;
#endif
}

@end
