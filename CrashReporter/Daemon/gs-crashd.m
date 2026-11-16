/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <Foundation/NSConnection.h>
#import <signal.h>
#import "GSCrashConstants.h"
#import "GSCrashPlatform.h"
#import "GSCrashDetector.h"
#import "GSCrashCollector.h"

/* Minimal fswatcher DO protocols (mirrors
 * gershwin-workspace/Tools/fswatcher/fswatcher.h) so we do not depend on the
 * Workspace build. The fswatcher daemon is the system-wide inotify/kqueue
 * directory watcher; subscribing to it replaces polling the crash inbox. */
@protocol FSWClientProtocol <NSObject>
- (oneway void)watchedPathDidChange:(NSData *)dirinfo;
- (oneway void)globalWatchedPathDidChange:(NSDictionary *)dirinfo;
@end

@protocol FSWatcherProtocol <NSObject>
- (oneway void)registerClient:(id <FSWClientProtocol>)client
              isGlobalWatcher:(BOOL)global;
- (oneway void)unregisterClient:(id <FSWClientProtocol>)client;
- (oneway void)client:(id <FSWClientProtocol>)client
                addWatcherForPath:(NSString *)path;
- (oneway void)client:(id <FSWClientProtocol>)client
             removeWatcherForPath:(NSString *)path;
@end

static volatile sig_atomic_t gTerminate = 0;
static id<GSCrashPlatform> gPlatform = nil;

static void handleTerm(int sig)
{
    (void)sig;
    gTerminate = 1;
}

@interface GSCrashController : NSObject <FSWClientProtocol>
{
    GSCrashDetector *_detector;
    GSCrashCollector *_collector;
    NSString *_inboxDir;
    NSString *_markersDir;
    id <FSWatcherProtocol> _fsw;
    BOOL _usingFSWatcher;
    NSTimer *_pollTimer;   /* fallback when fswatcher is unavailable */
    NSTimer *_retryTimer;  /* re-attempt fswatcher connection */
    NSTimer *_scanTimer;   /* debounce coalescing fswatcher bursts */
}
- (instancetype)initWithPlatform:(id<GSCrashPlatform>)platform
                         inboxDir:(NSString *)inboxDir
                       markersDir:(NSString *)markersDir;
- (void)start;
- (void)tick:(NSTimer *)timer;
@end

@implementation GSCrashController

- (instancetype)initWithPlatform:(id<GSCrashPlatform>)platform
                         inboxDir:(NSString *)inboxDir
                       markersDir:(NSString *)markersDir
{
    self = [super init];
    if (self)
    {
        _detector = [[GSCrashDetector alloc] initWithInbox:inboxDir
                                                   markers:markersDir
                                                  platform:platform];
        _collector = [[GSCrashCollector alloc] initWithPlatform:platform
                                                       inboxDir:inboxDir
                                                     markersDir:markersDir];
        _inboxDir = [inboxDir copy];
        _markersDir = [markersDir copy];
    }
    return self;
}

- (void)start
{
    /* Always keep a periodic scan as a safety net so crashes are never missed,
     * even if fswatcher events are not delivered. fswatcher, when available,
     * provides immediate notification on top of this. */
    [self startPolling];
    if ([self connectToFSWatcher])
    {
        _usingFSWatcher = YES;
        [_fsw registerClient:(id <FSWClientProtocol>)self isGlobalWatcher:NO];
        [_fsw client:(id <FSWClientProtocol>)self addWatcherForPath:_inboxDir];
        [_fsw client:(id <FSWClientProtocol>)self addWatcherForPath:_markersDir];
        NSLog(@"CrashReporter: watching crash dirs via fswatcher (polling safety net active)");
    }
    else
    {
        /* No fswatcher (e.g. Workspace not running): polling only, and keep
         * trying to adopt fswatcher in the background. */
        _retryTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                        target:self
                                                      selector:@selector(retryFSWatcher:)
                                                      userInfo:nil
                                                       repeats:YES];
        NSLog(@"CrashReporter: fswatcher unavailable, polling only");
    }
}

- (BOOL)connectToFSWatcher
{
    NSDistantObject *proxy =
        [NSConnection rootProxyForConnectionWithRegisteredName:@"fswatcher"
                                                           host:@""];
    if (proxy == nil)
        return NO;
    [proxy setProtocolForProxy:@protocol(FSWatcherProtocol)];
    _fsw = (id <FSWatcherProtocol>)proxy;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(fswatcherConnectionDidDie:)
               name:NSConnectionDidDieNotification
             object:[proxy connectionForProxy]];
    return YES;
}

- (void)fswatcherConnectionDidDie:(NSNotification *)notif
{
    (void)notif;
    _fsw = nil;
    _usingFSWatcher = NO;
    if (_scanTimer)
    {
        [_scanTimer invalidate];
        _scanTimer = nil;
    }
    [self startPolling];
    if (_retryTimer == nil)
        _retryTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                       target:self
                                                     selector:@selector(retryFSWatcher:)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)retryFSWatcher:(NSTimer *)timer
{
    (void)timer;
    if (_usingFSWatcher)
        return;
    if ([self connectToFSWatcher])
    {
        _usingFSWatcher = YES;
        [_fsw registerClient:(id <FSWClientProtocol>)self isGlobalWatcher:NO];
        [_fsw client:(id <FSWClientProtocol>)self addWatcherForPath:_inboxDir];
        [_fsw client:(id <FSWClientProtocol>)self addWatcherForPath:_markersDir];
        [_retryTimer invalidate];
        _retryTimer = nil;
        NSLog(@"CrashReporter: adopted fswatcher for crash monitoring (polling safety net stays on)");
    }
}

- (void)startPolling
{
    if (_pollTimer != nil)
        return;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:YES];
    NSLog(@"CrashReporter: fswatcher unavailable, falling back to polling");
}

/* FSWatcherProtocol: a watched directory changed. Coalesce bursts (a core file
 * is written in many small chunks) into a single scan after a short settle. */
- (oneway void)watchedPathDidChange:(NSData *)dirinfo
{
    (void)dirinfo;
    if (_scanTimer != nil)
        [_scanTimer invalidate];
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:NO];
}

- (oneway void)globalWatchedPathDidChange:(NSDictionary *)dirinfo
{
    (void)dirinfo;
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    _scanTimer = nil;
    @autoreleasepool
    {
        @try
        {
            NSArray *events = [_detector scan];
            for (GSCrashEvent *ev in events)
            {
                @try
                {
                    [_collector processEvent:ev];
                }
                @catch (NSException *e)
                {
                    NSLog(@"CrashReporter: error processing event %@: %@",
                          ev.path, e);
                }
            }
        }
        @catch (NSException *e)
        {
            NSLog(@"CrashReporter: scan tick error: %@", e);
        }
    }
}

@end

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    @autoreleasepool
    {
        signal(SIGTERM, handleTerm);
        signal(SIGINT, handleTerm);

        gPlatform = GSCrashPlatformForCurrentOS();

        NSString *base = GSCrashBaseDirectory();
        NSString *inboxDir = [base stringByAppendingPathComponent:@"inbox"];
        NSString *markersDir = [base stringByAppendingPathComponent:GSCrashMarkerDir];

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *d in @[ inboxDir, markersDir ])
        {
            if (![fm fileExistsAtPath:d])
                [fm createDirectoryAtPath:d
                    withIntermediateDirectories:YES
                                     attributes:@{ NSFilePosixPermissions : @(0700) }
                                          error:nil];
        }

        /* Configure core dumps into the inbox; best effort, degrade on failure
         * (e.g. an existing collector or lack of privilege) - never exit. */
        NSError *err = nil;
        if (![gPlatform configureCoreDumpsToDirectory:inboxDir error:&err])
            NSLog(@"CrashReporter: core-dump configuration degraded: %@",
                  [err localizedDescription]);
        err = nil;
        if (![gPlatform installCrashMonitor:&err])
            NSLog(@"CrashReporter: crash monitor install failed: %@",
                  [err localizedDescription]);

        NSLog(@"CrashReporter: gs-crashd started (platform=%@, inbox=%@)",
              [gPlatform platformName], inboxDir);

        GSCrashController *ctrl =
            [[GSCrashController alloc] initWithPlatform:gPlatform
                                              inboxDir:inboxDir
                                            markersDir:markersDir];
        [ctrl start];

        NSRunLoop *rl = [NSRunLoop currentRunLoop];
        while (!gTerminate)
            [rl runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];

        /* Restore only what we saved (SPEC 8). */
        if (![gPlatform restoreCoreConfiguration:&err])
            NSLog(@"CrashReporter: core configuration restore failed: %@",
                  [err localizedDescription]);

        NSLog(@"CrashReporter: gs-crashd stopped");
    }
    return 0;
}
