/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MouseBackend.h"

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#if defined(__linux__)
#include <linux/input.h>
#elif defined(__FreeBSD__)
#include <dev/evdev/input.h>
#endif

static NSString *const kNaturalScrollingProperty = @"libinput Natural Scrolling Enabled";
static NSString *const kLeftHandedProperty = @"libinput Left Handed Enabled";
static NSString *const kAccelSpeedProperty = @"libinput Accel Speed";

@interface MouseBackend ()
@property (nonatomic, readwrite, copy) NSString *xinputPath;
@property (nonatomic, readwrite, copy) NSString *touchpadName;
@property (nonatomic, readwrite, copy) NSString *mouseName;
@property (nonatomic, readwrite, copy) NSString *trackpointName;
@end

@implementation MouseBackend

+ (NSString *)findXinput
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        @"/usr/bin/xinput",
        @"/usr/local/bin/xinput",
        @"/opt/local/bin/xinput",
        @"/opt/bin/xinput",
        @"/usr/pkg/bin/xinput",
        @"/usr/X11R6/bin/xinput",
    ];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:@[@"xinput"]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *trim = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] > 0 && [fm isExecutableFileAtPath:trim]) {
        return trim;
    }
    return nil;
}

- (NSString *)runXinput:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:self.xinputPath];
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
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)matchesAny:(NSString *)name patterns:(NSArray *)patterns
{
    for (NSString *p in patterns) {
        if ([name rangeOfString:p].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (NSArray *)xinputDeviceNamesMatching:(NSString *)pattern
{
    if (!self.xinputPath) {
        return @[];
    }
    NSString *output = [self runXinput:@[@"list", @"--name-only"]];
    NSMutableArray *result = [NSMutableArray array];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line rangeOfString:pattern].location != NSNotFound) {
            [result addObject:[line copy]];
        }
    }
    return result;
}

- (void)refresh
{
    if (!self.xinputPath) {
        self.xinputPath = [[self class] findXinput];
    }
    self.touchpadName = nil;
    self.mouseName = nil;
    self.trackpointName = nil;

    // Check for touchpad using multiple patterns
    NSArray *tpNames = [self xinputDeviceNamesMatching:@"Touchpad"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"Synaptics"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"ELAN"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"Alps"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"bcm5974"];
    if ([tpNames count] == 0) tpNames = [self xinputDeviceNamesMatching:@"appletouch"];
    if ([tpNames count] > 0) {
        self.touchpadName = [tpNames objectAtIndex:0];
    }

    // TrackPoint
    NSArray *tppNames = [self xinputDeviceNamesMatching:@"TrackPoint"];
    if ([tppNames count] == 0) tppNames = [self xinputDeviceNamesMatching:@"Trackpoint"];
    if ([tppNames count] > 0) {
        self.trackpointName = [tppNames objectAtIndex:0];
    }

    // Mouse: first non-excluded name that isn't already classified
    NSArray *all = [self xinputDeviceNamesMatching:@""];
    for (NSString *name in all) {
        if ([self matchesAny:name patterns:@[
            @"XTEST", @"Virtual", @"virtual",
            @"keyboard", @"Keyboard", @"Button",
            @"HID ", @"HID/", @"Power Button",
            @"Sleep Button", @"Lid Switch", @"Video Bus",
            @"ums", @"wsmouse", @"sysmouse", @"pms",
        ]]) {
            continue;
        }
        if (self.touchpadName && [name isEqualToString:self.touchpadName]) continue;
        if (self.trackpointName && [name isEqualToString:self.trackpointName]) continue;
        if (self.mouseName == nil) {
            self.mouseName = name;
        }
    }
}

- (NSDictionary *)propertiesForDevice:(NSString *)device
{
    if (!self.xinputPath || !device) {
        return @{};
    }
    NSString *output = [self runXinput:@[@"list-props", device]];
    // xinput list-props output format:
    //   libprop Name (ID): value...
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *propName = nil;
        if (![scanner scanUpToString:@"(" intoString:&propName]) {
            continue;
        }
        propName = [propName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([propName length] == 0) {
            continue;
        }
        // skip the parenthesized ID
        [scanner scanUpToString:@"):" intoString:nil];
        if (![scanner scanString:@"):" intoString:nil]) {
            continue;
        }
        NSString *value = nil;
        [scanner scanUpToString:@"\n" intoString:&value];
        if (value) {
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if ([value length] > 0) {
            [result setObject:value forKey:propName];
        }
    }
    return result;
}

+ (NSString *)propertyValue:(NSDictionary *)props name:(NSString *)name
{
    return [props objectForKey:[@"libinput " stringByAppendingString:name]];
}

+ (double)unitsPerMMForProperties:(NSDictionary *)props
{
#if defined(__linux__) || defined(__FreeBSD__)
    NSString *node = [[props objectForKey:@"Device Node"]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    if ([node length] == 0) {
        return 0.0;
    }
    struct input_absinfo abs;
    int fd = open([node fileSystemRepresentation], O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        return 0.0;
    }
    int rc = ioctl(fd, EVIOCGABS(ABS_X), &abs);
    close(fd);
    return (rc == 0 && abs.resolution > 0) ? abs.resolution : 0.0;
#else
    (void)props;
    return 0.0;
#endif
}

/* A device class this machine does not have is not a failure: the setting
 * simply has nothing to act on. */
- (BOOL)setProperty:(NSString *)prop forDevice:(NSString *)device values:(NSArray *)values
{
    if (!device) {
        return YES;
    }
    if (!self.xinputPath) {
        return NO;
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:self.xinputPath];
    [task setArguments:[@[@"set-prop", device, prop] arrayByAddingObjectsFromArray:values]];
    [task launch];
    [task waitUntilExit];
    return [task terminationStatus] == 0;
}

- (BOOL)setProperty:(NSString *)prop forDevice:(NSString *)device value:(NSString *)value
{
    return [self setProperty:prop forDevice:device values:@[value]];
}

- (BOOL)setBoolProperty:(NSString *)prop forDevice:(NSString *)device value:(BOOL)value
{
    return [self setProperty:prop forDevice:device value:(value ? @"1" : @"0")];
}

/* Each xinput call runs even if an earlier one failed, so one broken device
 * does not hold back the others. */
- (BOOL)setBoolPropertyOnAllDevices:(NSString *)prop value:(BOOL)value
{
    BOOL ok = [self setBoolProperty:prop forDevice:self.touchpadName value:value];
    ok = [self setBoolProperty:prop forDevice:self.mouseName value:value] && ok;
    ok = [self setBoolProperty:prop forDevice:self.trackpointName value:value] && ok;
    return ok && self.xinputPath != nil;
}

- (NSString *)speedString:(float)speed
{
    return [NSString stringWithFormat:@"%.3f", speed];
}

- (BOOL)applyNaturalScrolling:(BOOL)enabled
{
    return [self setBoolPropertyOnAllDevices:kNaturalScrollingProperty value:enabled];
}

- (BOOL)applyLeftHanded:(BOOL)enabled
{
    return [self setBoolPropertyOnAllDevices:kLeftHandedProperty value:enabled];
}

/* The touchpad has its own speed, and libinput ignores it anyway while the
 * custom acceleration profile is on. */
- (BOOL)applyMouseSpeed:(float)speed
{
    return [self setProperty:kAccelSpeedProperty forDevice:self.mouseName
                       value:[self speedString:speed]] && self.xinputPath != nil;
}

- (BOOL)applyTrackpadSpeed:(float)speed
{
    return [self setProperty:kAccelSpeedProperty forDevice:self.touchpadName
                       value:[self speedString:speed]] && self.xinputPath != nil;
}

- (BOOL)applyTrackpointSpeed:(float)speed
{
    return [self setProperty:kAccelSpeedProperty forDevice:self.trackpointName
                       value:[self speedString:speed]] && self.xinputPath != nil;
}

- (BOOL)applyTapToClick:(BOOL)enabled
{
    return [self setBoolProperty:@"libinput Tapping Enabled"
                       forDevice:self.touchpadName value:enabled] && self.xinputPath != nil;
}

- (BOOL)applyTwoFingerRightClick:(BOOL)twoFinger threeFingerMiddleClick:(BOOL)threeFinger
{
    if (!self.touchpadName) {
        return self.xinputPath != nil;
    }
    /* libinput's tap mapping only chooses between left-right-middle (1, 0)
       and left-middle-right (0, 0); three-finger middle click on its own is
       the one combination that needs the second. */
    NSString *mapVal = (threeFinger && !twoFinger) ? @"0, 0" : @"1, 0";
    BOOL ok = [self setProperty:@"libinput Tapping Button Mapping"
                      forDevice:self.touchpadName value:mapVal];
    ok = [self setProperty:@"libinput Clickfinger Button Mapping"
                 forDevice:self.touchpadName value:@"1, 0"] && ok;
    return ok;
}

- (BOOL)applyDisableWhileTyping:(BOOL)enabled
{
    return [self setBoolProperty:@"libinput Disable While Typing Enabled"
                       forDevice:self.touchpadName value:enabled] && self.xinputPath != nil;
}


- (BOOL)applyTrackpadAccelProfile:(NSString *)profile
                     customPoints:(NSArray *)points
                             step:(double)step
{
    if (!self.touchpadName) {
        return self.xinputPath != nil;
    }
    /* Indexed like libinput's "Accel Profile Enabled" flags: adaptive, flat,
       custom. */
    NSArray *flags;
    if ([profile isEqualToString:@"custom"]) {
        NSMutableArray *values = [NSMutableArray array];
        for (NSNumber *point in points) {
            [values addObject:[NSString stringWithFormat:@"%.4f", [point doubleValue]]];
        }
        /* The points go first so that enabling the profile never runs on
           stale ones. */
        if (![self setProperty:@"libinput Accel Custom Motion Points"
                     forDevice:self.touchpadName values:values]
            || ![self setProperty:@"libinput Accel Custom Motion Step"
                        forDevice:self.touchpadName
                            value:[NSString stringWithFormat:@"%.4f", step]]) {
            return NO;
        }
        flags = @[@"0", @"0", @"1"];
    } else if ([profile isEqualToString:@"flat"]) {
        flags = @[@"0", @"1", @"0"];
    } else if ([profile isEqualToString:@"system"]) {
        flags = @[@"1", @"0", @"0"];
    } else {
        return NO;
    }
    return [self setProperty:@"libinput Accel Profile Enabled"
                   forDevice:self.touchpadName values:flags];
}

@end
