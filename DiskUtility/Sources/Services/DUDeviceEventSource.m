/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceEventSource.h"

#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/netlink.h>
#endif

// One plug produces a burst (disk, then each partition); refreshing after
// the burst, not per event, shows the finished picture once.
static const int kQuietMilliseconds = 300;
static const int kStopCheckMilliseconds = 500;

@implementation DUDeviceEventSource {
    int _fd;
    volatile BOOL _stopped;
    NSThread *_thread;
}

+ (instancetype)sourceForPlatform
{
#if defined(__linux__) || \
    (defined(__FreeBSD__) && !defined(__NetBSD__) && !defined(__OpenBSD__))
    return [[self alloc] init];
#else
    return nil;
#endif
}

- (instancetype)init
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _fd = -1;
    return self;
}

// Opens the platform channel; -1 with errno set when it cannot be had.
- (int)openChannel
{
#if defined(__linux__)
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_nl address;
    memset(&address, 0, sizeof(address));
    address.nl_family = AF_NETLINK;
    // Group 1 is the raw kernel broadcast; unlike udev's own group it needs
    // no privileges and does not depend on udev running.
    address.nl_groups = 1;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
#else
    int fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/var/run/devd.seqpacket.pipe",
            sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
#endif
}

// Whether one message concerns a disk coming, going or changing.
static BOOL MessageIsDiskEvent(const char *bytes, ssize_t length)
{
#if defined(__linux__)
    // "add@/devices/...\0KEY=VALUE\0..." - the subsystem is a key/value pair.
    const char *end = bytes + length;
    for (const char *cursor = bytes; cursor < end;
         cursor += strlen(cursor) + 1) {
        if (strcmp(cursor, "SUBSYSTEM=block") == 0) {
            return YES;
        }
    }
    return NO;
#else
    // "!system=DEVFS subsystem=CDEV type=CREATE cdev=da0"
    NSString *line = [[NSString alloc] initWithBytes:bytes
                                              length:(NSUInteger)length
                                            encoding:NSUTF8StringEncoding];
    if (line == nil || ![line hasPrefix:@"!system=DEVFS"]) {
        return NO;
    }
    BOOL change = [line containsString:@"type=CREATE"] ||
        [line containsString:@"type=DESTROY"] ||
        [line containsString:@"type=MEDIACHANGE"];
    if (!change) {
        return NO;
    }
    for (NSString *prefix in @[ @"cdev=da", @"cdev=ada", @"cdev=cd",
                                @"cdev=nda", @"cdev=nvd", @"cdev=mmcsd",
                                @"cdev=vtbd" ]) {
        if ([line containsString:prefix]) {
            return YES;
        }
    }
    return NO;
#endif
}

- (BOOL)startWithHandler:(void (^)(void))handler
{
    if (_thread != nil) {
        return YES;
    }
    _fd = [self openChannel];
    if (_fd < 0) {
        NSLog(@"DUDeviceEventSource: no event channel (%s); polling only",
              strerror(errno));
        return NO;
    }
    _stopped = NO;
    int fd = _fd;
    __weak DUDeviceEventSource *weakSelf = self;
    _thread = [[NSThread alloc] initWithBlock:^{
        char buffer[8192];
        BOOL pending = NO;
        for (;;) {
            DUDeviceEventSource *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_stopped) {
                break;
            }
            struct pollfd descriptor = { .fd = fd, .events = POLLIN };
            int timeout = pending ? kQuietMilliseconds
                                  : kStopCheckMilliseconds;
            int ready = poll(&descriptor, 1, timeout);
            if (ready < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            if (ready == 0) {
                if (pending) {
                    pending = NO;
                    @autoreleasepool {
                        handler();
                    }
                }
                continue;
            }
            ssize_t got = recv(fd, buffer, sizeof(buffer), 0);
            if (got <= 0) {
                if (got < 0 && (errno == EINTR || errno == EAGAIN ||
                                errno == ENOBUFS)) {
                    // A burst overflowed the socket buffer: events were
                    // lost, so refresh once the burst ends.
                    pending = pending || errno == ENOBUFS;
                    continue;
                }
                break;
            }
            if (MessageIsDiskEvent(buffer, got)) {
                pending = YES;
            }
        }
    }];
    _thread.name = @"DUDeviceEvents";
    [_thread start];
    return YES;
}

- (void)stop
{
    _stopped = YES;
}

- (void)dealloc
{
    _stopped = YES;
    if (_fd >= 0) {
        close(_fd);
    }
}

@end
