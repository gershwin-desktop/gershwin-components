/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "FreeBSDBacklightBackend.h"

#ifdef __FreeBSD__

#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/backlight.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

/* backlight(8) uses the first device unless told otherwise; laptops have
   exactly one panel backlight. */
static const char *kBacklightDevice = "/dev/backlight/backlight0";

@implementation FreeBSDBacklightBackend
{
    int _fd;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fd = open(kBacklightDevice, O_RDWR | O_CLOEXEC);
        if (_fd < 0) {
            /* ENOENT: no backlight driver; EACCES: devfs.rules must grant the
               user access, as for backlight(8) without root. */
            NSLog(@"FreeBSDBacklightBackend: Cannot open %s: %s", kBacklightDevice, strerror(errno));
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    close(_fd);
}

- (int)current
{
    struct backlight_props props;
    memset(&props, 0, sizeof(props));
    if (ioctl(_fd, BACKLIGHTGETSTATUS, &props) != 0) {
        NSLog(@"FreeBSDBacklightBackend: BACKLIGHTGETSTATUS failed: %s", strerror(errno));
        return 0;
    }
    return (int)props.brightness;
}

- (int)maximum
{
    return 100;
}

- (void)set:(int)value
{
    struct backlight_props props;
    memset(&props, 0, sizeof(props));
    props.brightness = (uint32_t)MAX(0, MIN(value, 100));
    if (ioctl(_fd, BACKLIGHTUPDATESTATUS, &props) != 0) {
        NSLog(@"FreeBSDBacklightBackend: BACKLIGHTUPDATESTATUS failed: %s", strerror(errno));
    }
}

@end

#endif
