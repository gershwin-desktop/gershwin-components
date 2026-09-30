/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceMonitor.h"

#import "DUErrors.h"
#import "DUStorageManager.h"

// Defaults key overriding the poll interval in seconds.
static NSString *const DURefreshIntervalDefaultsKey = @"DURefreshInterval";
static const NSTimeInterval DUDefaultRefreshInterval = 10.0;

@implementation DUDeviceMonitor {
    DUStorageManager *_storageManager;
    NSTimer *_timer;
    NSLock *_lock;
    BOOL _refreshInFlight; // Skips ticks when the previous one still runs.
}

- (instancetype)initWithStorageManager:(DUStorageManager *)storageManager
{
    NSParameterAssert(storageManager != nil);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _storageManager = storageManager;
    _lock = [[NSLock alloc] init];
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
    return DUDefaultRefreshInterval;
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
    [[NSRunLoop currentRunLoop] addTimer:armed forMode:NSRunLoopCommonModes];
}

- (void)start
{
    [_lock lock];
    if (_timer != nil) {
        [_lock unlock];
        return;
    }
    // Retained cycle is deliberate and broken in -stop/dealloc.
    _timer = [NSTimer timerWithTimeInterval:_interval
                                     target:self
                                   selector:@selector(timerFired:)
                                   userInfo:nil
                                    repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [_lock unlock];

    // First snapshot right away so the UI does not start empty.
    [self refreshOnce];
}

- (void)stop
{
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
                [self->_lock unlock];
            }
        }
    }];
    thread.name = @"DUDeviceMonitor refresh";
    [thread start];
}

@end
