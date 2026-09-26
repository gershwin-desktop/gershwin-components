/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "EnergyBackend.h"
#import <time.h>

@implementation EnergyBackend

+ (NSString *)readFile:(NSString *)path
{
    NSString *content = [[NSString alloc] initWithContentsOfFile:path
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
    return [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)writeSysfs:(NSString *)path value:(NSString *)value
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:
        @"-c",
        [NSString stringWithFormat:@"printf '%s' '%@' | /usr/bin/sudo tee '%@' > /dev/null",
            [value UTF8String], value, path],
        nil]];
    [task launch];
    [task waitUntilExit];
    int status = [task terminationStatus];
    return (status == 0);
}

+ (NSString *)runCommand:(NSString *)cmd args:(NSArray *)args
{
    /* hdparm, ethtool, xbacklight and friends are optional packages; NSTask
       raises for a missing binary, which would take down the pane or the
       login-time re-apply instead of just this one reading. */
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:cmd]) {
        NSLog(@"EnergyBackend: %@ is not installed", cmd);
        return @"";
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:cmd];
    [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];

    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}


+ (NSDictionary *)readBatteryInfo
{
    NSString *source = @"Unknown";
    int percent = -1;
    NSString *status = @"";

#if defined(__linux__)
    NSString *acOnline = [self readFile:@"/sys/class/power_supply/AC/online"];
    NSString *battCap = [self readFile:@"/sys/class/power_supply/BAT0/capacity"];
    NSString *battStatus = [self readFile:@"/sys/class/power_supply/BAT0/status"];

    source = [acOnline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([battCap length] > 0) percent = [battCap intValue];
    if ([battStatus length] > 0) status = [battStatus capitalizedString];
#elif defined(__FreeBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.acline", nil]];
    NSString *life = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.life", nil]];
    NSString *state = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.state", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        status = (s == 1) ? @"Discharging" :
                 (s == 2) ? @"Charging" :
                 (s == 7) ? @"Charged" :
                 (s == 0) ? @"Idle" : state;
    }
#elif defined(__OpenBSD__)
    NSString *acline = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-a", nil]];
    NSString *life = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-l", nil]];
    NSString *bstate = [self runCommand:@"/usr/sbin/apm" args:[NSArray arrayWithObjects:@"-b", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([bstate length] > 0) {
        int s = [bstate intValue];
        status = (s == 0) ? @"High" :
                 (s == 1) ? @"Low" :
                 (s == 2) ? @"Critical" :
                 (s == 3) ? @"Charging" : bstate;
    }
#elif defined(__NetBSD__)
    NSString *acline = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.acline", nil]];
    NSString *life = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.life", nil]];
    NSString *state = [self runCommand:@"/sbin/sysctl" args:[NSArray arrayWithObjects:@"-n", @"hw.acpi.battery.state", nil]];

    source = [acline isEqualToString:@"1"] ? @"AC" : @"Battery";
    if ([life length] > 0) percent = [life intValue];
    if ([state length] > 0) {
        int s = [state intValue];
        status = (s == 1) ? @"Discharging" :
                 (s == 2) ? @"Charging" :
                 (s == 7) ? @"Charged" : state;
    }
#endif
    return [NSDictionary dictionaryWithObjectsAndKeys:
        source, @"source",
        [NSNumber numberWithInt:percent], @"percent",
        status, @"status", nil];
}

+ (int)readBrightnessPercent
{
#if defined(__linux__)
    int maxBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/max_brightness"] intValue];
    int curBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/brightness"] intValue];
    if (maxBrightness > 0) {
        return (curBrightness * 100 / maxBrightness);
    }
    return 100;
#elif defined(__FreeBSD__) || defined(__NetBSD__)
    NSString *b = [self runCommand:@"/usr/local/bin/xbacklight"
                             args:[NSArray arrayWithObjects:@"-get", nil]];
    if ([b length] > 0) {
        return (int)([b doubleValue] + 0.5);
    }
    return 100;
#elif defined(__OpenBSD__)
    NSString *b = [self runCommand:@"/usr/sbin/wsconsctl"
                             args:[NSArray arrayWithObjects:@"brightness", nil]];
    if ([b length] == 0) {
        b = [self runCommand:@"/usr/local/bin/xbacklight"
                       args:[NSArray arrayWithObjects:@"-get", nil]];
    }
    if ([b length] > 0) {
        return (int)([b doubleValue] + 0.5);
    }
    return 100;
#else
    return 100;
#endif
}

+ (BOOL)setBrightnessPercent:(int)pct
{
    if (pct < 1) pct = 1;
#if defined(__linux__)
    int maxBrightness = [[self readFile:@"/sys/class/backlight/intel_backlight/max_brightness"] intValue];
    if (maxBrightness > 0) {
        int val = (pct * maxBrightness) / 100;
        return [self writeSysfs:@"/sys/class/backlight/intel_backlight/brightness"
                          value:[NSString stringWithFormat:@"%d", val]];
    }
    return NO;
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
    /* xbacklight works on all BSDs with X11 */
    [self runCommand:@"/usr/local/bin/xbacklight"
                args:[NSArray arrayWithObjects:@"-set", [NSString stringWithFormat:@"%d", pct], nil]];
    /* On OpenBSD, also try wsconsctl */
#if defined(__OpenBSD__)
    [self runCommand:@"/usr/sbin/wsconsctl"
                args:[NSArray arrayWithObjects:@"brightness", [NSString stringWithFormat:@"%d", pct], nil]];
#endif
    return YES;
#else
    return YES;
#endif
}

+ (BOOL)readHddSleep
{
#if defined(__linux__)
    NSArray *disks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/block" error:NULL];
    for (NSString *d in disks) {
        if ([d hasPrefix:@"sd"] || [d hasPrefix:@"nvme"]) {
            NSString *devPath = [NSString stringWithFormat:@"/dev/%@", d];
            NSString *out = [self runCommand:@"/usr/sbin/hdparm"
                                        args:[NSArray arrayWithObjects:@"-B", devPath, nil]];
            if ([out length] == 0) continue;
            NSScanner *scanner = [NSScanner scannerWithString:out];
            if ([scanner scanUpToString:@"APM_level" intoString:nil]) {
                int apm = 255;
                [scanner scanInt:&apm];
                if (apm >= 1 && apm <= 127) return YES;
            }
        }
    }
    return NO;
#else
    return NO;
#endif
}

+ (BOOL)setHddSleep:(BOOL)enable
{
#if defined(__linux__)
    NSArray *disks = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/block" error:NULL];
    for (NSString *d in disks) {
        if ([d hasPrefix:@"sd"] || [d hasPrefix:@"nvme"]) {
            NSString *devPath = [NSString stringWithFormat:@"/dev/%@", d];
            NSString *apmVal = enable ? @"1" : @"254";
            NSString *sdVal = enable ? @"120" : @"0";
            [self runCommand:@"/bin/sh"
                        args:[NSArray arrayWithObjects:@"-c",
                              [NSString stringWithFormat:@"/usr/bin/sudo /usr/sbin/hdparm -B %@ -S %@ '%@' > /dev/null 2>&1",
                               apmVal, sdVal, devPath], nil]];
        }
    }
    return YES;
#else
    return YES;
#endif
}

+ (BOOL)readWakeNetwork
{
#if defined(__linux__)
    NSArray *interfaces = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/class/net" error:NULL];
    for (NSString *iface in interfaces) {
        if ([iface isEqualToString:@"lo"]) continue;
        NSString *out = [self runCommand:@"/usr/sbin/ethtool"
                                    args:[NSArray arrayWithObjects:iface, nil]];
        if ([out rangeOfString:@"Wake-on: g"].location != NSNotFound) return YES;
        if ([out rangeOfString:@"Wake-on: p"].location != NSNotFound) return YES;
    }
    return NO;
#else
    return NO;
#endif
}

+ (BOOL)setWakeNetwork:(BOOL)enable
{
#if defined(__linux__)
    NSArray *interfaces = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/sys/class/net" error:NULL];
    for (NSString *iface in interfaces) {
        if ([iface isEqualToString:@"lo"]) continue;
        NSString *wol = enable ? @"g" : @"d";
        [self runCommand:@"/bin/sh"
                    args:[NSArray arrayWithObjects:@"-c",
                          [NSString stringWithFormat:@"/usr/bin/sudo /usr/sbin/ethtool -s '%@' wol %@ > /dev/null 2>&1",
                           iface, wol], nil]];
    }
    return YES;
#else
    return YES;
#endif
}

+ (BOOL)readPowerFail
{
#if defined(__linux__)
    NSString *wakealarm = [self readFile:@"/sys/class/rtc/rtc0/wakealarm"];
    return ([wakealarm length] > 0 && ![wakealarm isEqualToString:@"0"]);
#else
    return NO;
#endif
}

+ (BOOL)setPowerFail:(BOOL)enable
{
#if defined(__linux__)
    if (enable) {
        time_t now = time(NULL);
        time_t then = now + 86400;
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm" value:@"0"];
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm"
                   value:[NSString stringWithFormat:@"%ld", (long)then]];
    } else {
        [self writeSysfs:@"/sys/class/rtc/rtc0/wakealarm" value:@"0"];
    }
    return YES;
#else
    return YES;
#endif
}

+ (NSArray<NSNumber *> *)screenBlankChoices
{
    return @[@0, @60, @300, @600, @900, @1800];
}

+ (NSString *)titleForScreenBlankSeconds:(int)seconds
{
    if (seconds <= 0) {
        return @"Never";
    }
    if (seconds == 60) {
        return @"1 minute";
    }
    return [NSString stringWithFormat:@"%d minutes", seconds / 60];
}

+ (NSUInteger)screenBlankChoiceIndexForSeconds:(int)seconds
{
    NSArray *choices = [self screenBlankChoices];
    NSUInteger i;
    if (seconds <= 0) {
        return 0;
    }
    for (i = 1; i < [choices count]; i++) {
        if (seconds <= [[choices objectAtIndex:i] intValue]) {
            return i;
        }
    }
    return [choices count] - 1;
}

+ (int)currentScreenBlankSeconds
{
    NSString *xsetOut = [self runCommand:@"/usr/bin/xset" args:@[@"q"]];
    if ([xsetOut rangeOfString:@"DPMS is Enabled"].location == NSNotFound) {
        return 0;
    }
    NSScanner *scanner = [NSScanner scannerWithString:xsetOut];
    int standby = 0;
    if ([scanner scanUpToString:@"Standby:" intoString:nil]) {
        [scanner scanString:@"Standby:" intoString:nil];
        [scanner scanInt:&standby];
    }
    return standby;
}

+ (BOOL)setScreenBlankSeconds:(int)seconds
{
    // DPMS: xset dpms <standby> <suspend> <off>
    NSString *blankStr = (seconds > 0) ? [NSString stringWithFormat:@"%d", seconds] : @"0";
    [self runCommand:@"/usr/bin/xset" args:@[@"dpms", blankStr, blankStr, blankStr]];
    if (seconds == 0) {
        [self runCommand:@"/usr/bin/xset" args:@[@"-dpms"]];
    } else {
        [self runCommand:@"/usr/bin/xset" args:@[@"+dpms"]];
    }
    return [self currentScreenBlankSeconds] == seconds;
}

@end
