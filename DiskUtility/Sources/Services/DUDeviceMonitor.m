/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceMonitor.h"

#import "DUDeviceEventSource.h"
#import "DUErrors.h"
#import "DUStorageManager.h"

// Defaults key overriding the poll interval in seconds.
static NSString *const DURefreshIntervalDefaultsKey = @"DURefreshInterval";
// With kernel events the poll is only a safety net for lost events; without
// them it is the only way to notice a plugged disk, so it runs often.
static const NSTimeInterval DUEventBackedRefreshInterval = 30.0;
static const NSTimeInterval DUPollOnlyRefreshInterval = 3.0;

@implementation DUDeviceMonitor {
    DUStorageManager *_storageManager;
    NSTimer *_timer;
    NSLock *_lock;
    BOOL _refreshInFlight; // Skips ticks when the previous one still runs.
    BOOL _refreshRequestedWhileBusy; // An event arrived mid-refresh.
    DUDeviceEventSource *_eventSource;
    BOOL _eventsActive;
}

- (instancetype)initWithStorageManager:(DUStorageManager *)storageManager
{
    NSParameterAssert(storageManager != nil);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _storageManager = storageManager;
    _lock = [[NSLock alloc] init];
    _eventSource = [DUDeviceEventSource sourceForPlatform];
    _interval = [self configuredInterval];

    // The interval was read once at init and the timer armed from it, so
    // changing the preference in Preferences did nothing until the app was
    // restarted - the control looked broken. Re-arm on the change instead.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(defaultsChanged:)
               name:NSUserDefaultsDidChangeNotification
             object:nil];
    return self;
}

- (NSTimeInterval)configuredInterval
{
    NSNumber *configured =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:DURefreshIntervalDefaultsKey];
    if (configured != nil && configured.doubleValue >= 1.0) {
        return configured.doubleValue;
    }
    return _eventsActive ? DUEventBackedRefreshInterval
                         : DUPollOnlyRefreshInterval;
}

- (void)defaultsChanged:(NSNotification *)notification
{
    (void)notification;
    NSTimeInterval wanted = [self configuredInterval];
    [_lock lock];
    BOOL same = wanted == _interval;
    NSTimer *timer = _timer;
    [_lock unlock];
    if (same || timer == nil) {
        return;
    }
    [_lock lock];
    _interval = wanted;
    [_timer invalidate];
    _timer = [NSTimer timerWithTimeInterval:_interval
                                     target:self
                                   selector:@selector(timerFired:)
                                   userInfo:nil
                                    repeats:YES];
    NSTimer *armed = _timer;
    [_lock unlock];
    [self schedule:armed];
}

// The common-modes pseudo mode never fired the timer on this run loop, so
// plugging or unplugging a disk went unnoticed; the concrete modes do. The
// tracking and modal modes keep the list live during menus and sheets.
- (void)schedule:(NSTimer *)timer
{
    NSRunLoop *loop = [NSRunLoop currentRunLoop];
    [loop addTimer:timer forMode:NSDefaultRunLoopMode];
    // Literal mode names: this file stays Foundation-only (the manager tests
    // link it without AppKit).
    [loop addTimer:timer forMode:@"NSEventTrackingRunLoopMode"];
    [loop addTimer:timer forMode:@"NSModalPanelRunLoopMode"];
}

- (void)start
{
    [_lock lock];
    if (_timer != nil) {
        [_lock unlock];
        return;
    }
    // Events first: whether they are available decides the poll interval.
    __weak DUDeviceMonitor *weakSelf = self;
    _eventsActive = [_eventSource startWithHandler:^{
        [weakSelf refreshOnce];
    }];
    _interval = [self configuredInterval];
    // Retained cycle is deliberate and broken in -stop/dealloc.
    _timer = [NSTimer timerWithTimeInterval:_interval
                                     target:self
                                   selector:@selector(timerFired:)
                                   userInfo:nil
                                    repeats:YES];
    NSTimer *armed = _timer;
    [_lock unlock];
    [self schedule:armed];

    // First snapshot right away so the UI does not start empty.
    [self refreshOnce];
}

- (void)stop
{
    [_eventSource stop];
    [_lock lock];
    if (_timer != nil) {
        [_timer invalidate];
        _timer = nil;
    }
    [_lock unlock];
}

- (void)dealloc
{
    // Timers retain their target; if we are deallocating anyway, make sure
    // the run loop lets go too.
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)timerFired:(NSTimer *)timer
{
    (void)timer;
    [self refreshOnce];
}

- (void)refreshOnce
{
    [_lock lock];
    if (_refreshInFlight) {
        // The running pass may have read the disks before this change.
        _refreshRequestedWhileBusy = YES;
        [_lock unlock];
        return;
    }
    _refreshInFlight = YES;
    [_lock unlock];

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            /* The in-flight flag MUST be cleared however this attempt ends.
             * It used to be set to NO after the refresh call, so any
             * exception raised inside discovery (a device node that vanishes
             * mid-walk) left it set for good: every later tick returned
             * immediately and the app never noticed a disk being plugged,
             * unplugged or repartitioned again. */
            @try {
                NSError *error = nil;
                // A failed poll keeps the previous snapshot; discovery errors
                // on transient devices are routine and must not tear down the
                // model.
                if (![self.storageManager refreshWithError:&error] &&
                    error != nil) {
                    NSLog(@"DUDeviceMonitor: refresh failed: %@",
                          error.localizedDescription);
                }
            } @finally {
                [self->_lock lock];
                self->_refreshInFlight = NO;
                BOOL again = self->_refreshRequestedWhileBusy;
                self->_refreshRequestedWhileBusy = NO;
                [self->_lock unlock];
                if (again) {
                    [self refreshOnce];
                }
            }
        }
    }];
    thread.name = @"DUDeviceMonitor refresh";
    [thread start];
}

@end
