/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "MouseBackend.h"

#include <fcntl.h>
#include <math.h>
#include <unistd.h>
#include <sys/ioctl.h>
#if defined(__linux__)
#include <linux/input.h>
#elif defined(__FreeBSD__)
#include <dev/evdev/input.h>
#endif

/* libinput's own scroll distance and the range xf86-input-libinput takes. */
static const double kDefaultScrollPixelDistance = 15.0;
static const int kMinScrollPixelDistance = 10;
static const int kMaxScrollPixelDistance = 1000;
/* The slow end of the pane's scroll speed slider. */
static const double kMinScrollSpeed = 0.25;

@interface MouseBackend ()
@property (nonatomic, readwrite, copy) NSString *xinputPath;
@property (nonatomic, readwrite, copy) NSArray *devices;
@end

@implementation MouseBackend

/* The pane itself only loads when xinput is on PATH (MousePane
   +isCompatible), so PATH comes first; the fixed locations cover a login
   script started with a minimal PATH. */
+ (NSString *)findXinput
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        if ([dir length] > 0) {
            [candidates addObject:[dir stringByAppendingPathComponent:@"xinput"]];
        }
    }
    [candidates addObjectsFromArray:@[
        @"/usr/bin/xinput",
        @"/usr/local/bin/xinput",
        @"/usr/X11R6/bin/xinput",
        @"/usr/pkg/bin/xinput",
    ]];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (instancetype)init
{
    return [self initWithXinputPath:[[self class] findXinput]];
}

- (instancetype)initWithXinputPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _xinputPath = [path copy];
        _devices = @[];
    }
    return self;
}

- (NSTask *)xinputTask:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:self.xinputPath];
    [task setArguments:args];
    /* The C locale keeps number formats in xinput's output parseable. */
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    return task;
}

- (NSString *)runXinput:(NSArray *)args
{
    NSTask *task = [self xinputTask:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)refresh
{
    if (!self.xinputPath) {
        self.devices = @[];
        return;
    }
    NSMutableArray *devices = [NSMutableArray array];
    for (NSDictionary *pointer in [PointerDevice slavePointersInXinputList:[self runXinput:@[@"list"]]]) {
        NSString *deviceID = [pointer objectForKey:@"id"];
        NSString *name = [pointer objectForKey:@"name"];
        NSDictionary *props = [PointerDevice propertiesFromXinputListProps:
            [self runXinput:@[@"list-props", deviceID]]];
        PointerDeviceKind kind = [PointerDevice kindForName:name properties:props];
        if (kind == PointerDeviceKindNone) {
            continue;
        }
        [devices addObject:[[PointerDevice alloc] initWithID:deviceID name:name kind:kind
            properties:props unitsPerMM:[[self class] unitsPerMMForKind:kind properties:props]]];
    }
    self.devices = devices;
}

- (NSArray *)devicesOfKind:(PointerDeviceKind)kind
{
    NSMutableArray *result = [NSMutableArray array];
    for (PointerDevice *d in self.devices) {
        if (d.kind == kind) {
            [result addObject:d];
        }
    }
    return result;
}

+ (double)unitsPerMMForKind:(PointerDeviceKind)kind properties:(NSDictionary *)properties
{
    if (kind != PointerDeviceKindTouchpad) {
        return AccelerationMouseUnitsPerMM;
    }
#if defined(__linux__) || defined(__FreeBSD__)
    NSString *node = [[properties objectForKey:@"Device Node"]
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
    (void)properties;
    return 0.0;
#endif
}

#pragma mark - Setting properties

- (BOOL)setProperty:(NSString *)prop onDevice:(PointerDevice *)device values:(NSArray *)values
{
    NSTask *task = [self xinputTask:[@[@"set-prop", device.deviceID, prop]
                                        arrayByAddingObjectsFromArray:values]];
    [task launch];
    [task waitUntilExit];
    if ([task terminationStatus] != 0) {
        NSLog(@"MouseBackend: xinput set-prop %@ '%@' %@ failed", device.deviceID, prop,
              [values componentsJoinedByString:@" "]);
        return NO;
    }
    return YES;
}

/* Each device is set even if an earlier one failed, so one broken device
   does not hold back the others.  A device where want() is NO is skipped;
   no xinput is a failure, an absent class is not. */
- (BOOL)forDevicesOfKind:(PointerDeviceKind)kind
                    want:(BOOL (^)(PointerDevice *device))want
                     set:(BOOL (^)(PointerDevice *device))set
{
    if (!self.xinputPath) {
        return NO;
    }
    BOOL ok = YES;
    for (PointerDevice *d in [self devicesOfKind:kind]) {
        if (want == nil || want(d)) {
            ok = set(d) && ok;
        }
    }
    return ok;
}

- (BOOL)setProperty:(NSString *)prop values:(NSArray *)values toKind:(PointerDeviceKind)kind
{
    return [self forDevicesOfKind:kind want:nil set:^BOOL(PointerDevice *d) {
        return [self setProperty:prop onDevice:d values:values];
    }];
}

static NSArray *BoolValue(BOOL value)
{
    return @[value ? @"1" : @"0"];
}

- (BOOL)applySpeed:(float)speed toKind:(PointerDeviceKind)kind
{
    return [self setProperty:@"libinput Accel Speed"
                      values:@[[NSString stringWithFormat:@"%.3f", speed]] toKind:kind];
}

- (BOOL)applyNaturalScrolling:(BOOL)enabled toKind:(PointerDeviceKind)kind
{
    return [self setProperty:@"libinput Natural Scrolling Enabled" values:BoolValue(enabled) toKind:kind];
}

- (BOOL)applyLeftHanded:(BOOL)enabled toKind:(PointerDeviceKind)kind
{
    return [self setProperty:@"libinput Left Handed Enabled" values:BoolValue(enabled) toKind:kind];
}

- (BOOL)applyScrollSpeed:(double)speed toKind:(PointerDeviceKind)kind
{
    NSString *prop = @"libinput Scrolling Pixel Distance";
    NSArray *values = @[[NSString stringWithFormat:@"%d", [[self class] scrollPixelDistanceForSpeed:speed]]];
    return [self forDevicesOfKind:kind
                             want:^BOOL(PointerDevice *d) { return [d.properties objectForKey:prop] != nil; }
                              set:^BOOL(PointerDevice *d) { return [self setProperty:prop onDevice:d values:values]; }];
}

+ (int)scrollPixelDistanceForSpeed:(double)speed
{
    if (speed <= 0.0) {
        return kMaxScrollPixelDistance;
    }
    long distance = lround(kDefaultScrollPixelDistance / speed);
    return (int)MAX(kMinScrollPixelDistance, MIN(kMaxScrollPixelDistance, distance));
}

+ (double)scrollSpeedForPixelDistance:(int)distance
{
    return kDefaultScrollPixelDistance / MAX(kMinScrollPixelDistance, distance);
}

+ (double)minimumScrollSpeed
{
    return kMinScrollSpeed;
}

+ (double)maximumScrollSpeed
{
    return kDefaultScrollPixelDistance / kMinScrollPixelDistance;
}

- (BOOL)applyAccelProfile:(NSString *)profile
                    curve:(AccelerationCurve)curve
                   toKind:(PointerDeviceKind)kind
{
    /* Indexed like libinput's "Accel Profile Enabled" flags: adaptive,
       flat, custom. */
    NSArray *flags;
    BOOL custom = NO;
    if ([profile isEqualToString:@"custom"]) {
        flags = @[@"0", @"0", @"1"];
        custom = YES;
    } else if ([profile isEqualToString:@"flat"]) {
        flags = @[@"0", @"1", @"0"];
    } else if ([profile isEqualToString:@"system"]) {
        flags = @[@"1", @"0", @"0"];
    } else {
        return NO;
    }
    return [self forDevicesOfKind:kind want:nil set:^BOOL(PointerDevice *d) {
        if (custom) {
            if (d.unitsPerMM <= 0.0) {
                NSLog(@"MouseBackend: no resolution for %@, custom acceleration refused", d.name);
                return NO;
            }
            NSMutableArray *points = [NSMutableArray array];
            for (NSNumber *p in AccelerationCurvePoints(kind, curve, d.unitsPerMM)) {
                [points addObject:[NSString stringWithFormat:@"%.6f", [p doubleValue]]];
            }
            NSString *step = [NSString stringWithFormat:@"%.6f",
                AccelerationCurvePointStep(kind, d.unitsPerMM)];
            /* The points go first so that enabling the profile never runs
               on stale ones. */
            if (![self setProperty:@"libinput Accel Custom Motion Points" onDevice:d values:points]
                || ![self setProperty:@"libinput Accel Custom Motion Step" onDevice:d values:@[step]]) {
                return NO;
            }
        }
        return [self setProperty:@"libinput Accel Profile Enabled" onDevice:d values:flags];
    }];
}

#pragma mark - Touchpad only

- (BOOL)applyTapToClick:(BOOL)enabled
{
    return [self setProperty:@"libinput Tapping Enabled" values:BoolValue(enabled)
                      toKind:PointerDeviceKindTouchpad];
}

- (BOOL)applyTwoFingerRightClick:(BOOL)twoFinger threeFingerMiddleClick:(BOOL)threeFinger
{
    /* libinput has exactly two finger-to-button maps, left-right-middle
       (1, 0) and left-middle-right (0, 1); two-finger right click and
       three-finger middle click are both the first, so the second only
       follows when both are off.  Clicking with fingers on a clickpad
       follows the same map where the driver has it. */
    NSArray *map = (twoFinger || threeFinger) ? @[@"1", @"0"] : @[@"0", @"1"];
    NSString *clickfinger = @"libinput Clickfinger Button Mapping Enabled";
    return [self forDevicesOfKind:PointerDeviceKindTouchpad want:nil set:^BOOL(PointerDevice *d) {
        BOOL ok = [self setProperty:@"libinput Tapping Button Mapping Enabled" onDevice:d values:map];
        if ([d.properties objectForKey:clickfinger] != nil) {
            ok = [self setProperty:clickfinger onDevice:d values:map] && ok;
        }
        return ok;
    }];
}

- (BOOL)applyDisableWhileTyping:(BOOL)enabled
{
    return [self setProperty:@"libinput Disable While Typing Enabled" values:BoolValue(enabled)
                      toKind:PointerDeviceKindTouchpad];
}

@end
