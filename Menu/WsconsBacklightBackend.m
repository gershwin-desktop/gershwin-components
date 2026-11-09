/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WsconsBacklightBackend.h"

#if defined(__OpenBSD__) || defined(__NetBSD__)

#import <sys/types.h>
#import <sys/ioctl.h>
#import <sys/time.h>
#import <dev/wscons/wsconsio.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

/* The first virtual terminal carries the display the X server runs on;
   wsconsctl opens the same device. */
#if defined(__OpenBSD__)
static const char *kDisplayDevice = "/dev/ttyC0";
#else
static const char *kDisplayDevice = "/dev/ttyE0";
#endif

@implementation WsconsBacklightBackend
{
    int _fd;
    int _min;
    int _max;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fd = open(kDisplayDevice, O_RDWR | O_CLOEXEC);
        if (_fd < 0) {
            NSLog(@"WsconsBacklightBackend: Cannot open %s: %s", kDisplayDevice, strerror(errno));
            return nil;
        }
        struct wsdisplay_param param;
        memset(&param, 0, sizeof(param));
        param.param = WSDISPLAYIO_PARAM_BRIGHTNESS;
        if (ioctl(_fd, WSDISPLAYIO_GETPARAM, &param) != 0) {
            /* The display driver has no backlight control. */
            NSLog(@"WsconsBacklightBackend: No brightness parameter on %s: %s", kDisplayDevice, strerror(errno));
            close(_fd);
            return nil;
        }
        _min = param.min;
        _max = param.max;
    }
    return self;
}

- (void)dealloc
{
    close(_fd);
}

/* The protocol counts from zero; wscons ranges may not. */
- (int)current
{
    struct wsdisplay_param param;
    memset(&param, 0, sizeof(param));
    param.param = WSDISPLAYIO_PARAM_BRIGHTNESS;
    if (ioctl(_fd, WSDISPLAYIO_GETPARAM, &param) != 0) {
        NSLog(@"WsconsBacklightBackend: WSDISPLAYIO_GETPARAM failed: %s", strerror(errno));
        return 0;
    }
    return param.curval - _min;
}

- (int)maximum
{
    return _max - _min;
}

- (void)set:(int)value
{
    struct wsdisplay_param param;
    memset(&param, 0, sizeof(param));
    param.param = WSDISPLAYIO_PARAM_BRIGHTNESS;
    param.curval = _min + MAX(0, MIN(value, _max - _min));
    if (ioctl(_fd, WSDISPLAYIO_SETPARAM, &param) != 0) {
        NSLog(@"WsconsBacklightBackend: WSDISPLAYIO_SETPARAM failed: %s", strerror(errno));
    }
}

@end

#endif
