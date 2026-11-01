/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashCollector.h"
#import "GSCrashConstants.h"
#import "GSCrashReport.h"
#import "GSCrashPlatform.h"
#import <sys/stat.h>
#import <unistd.h>

@interface GSCrashCollector ()
{
    id<GSCrashPlatform> _platform;
    NSString *_inboxDir;
    NSString *_markersDir;
    NSString *_processedMarkersDir;
    NSString *_pendingDir;
    NSFileManager *_fm;
    /* pid (NSNumber) -> crash directory, for Method C/A correlation. */
    NSMutableDictionary *_pidToCrashDir;
}
@end

@implementation GSCrashCollector

- (instancetype)initWithPlatform:(id<GSCrashPlatform>)platform
                       inboxDir:(NSString *)inboxDir
                     markersDir:(NSString *)markersDir
{
    self = [super init];
    if (self)
    {
        _platform = platform;
        _inboxDir = [inboxDir copy];
        _markersDir = [markersDir copy];
        _fm = [NSFileManager defaultManager];
        _pidToCrashDir = [NSMutableDictionary dictionary];
        NSString *base = GSCrashBaseDirectory();
        _processedMarkersDir = [markersDir stringByAppendingPathComponent:@"processed"];
        _pendingDir = [base stringByAppendingPathComponent:@"pending"];
        [self ensureDir:_processedMarkersDir perms:0700];
        [self ensureDir:_pendingDir perms:0700];
    }
    return self;
}

- (void)ensureDir:(NSString *)dir perms:(mode_t)perms
{
    if (![_fm fileExistsAtPath:dir])
    {
        NSError *e = nil;
        if (![_fm createDirectoryAtPath:dir
                withIntermediateDirectories:YES
                                 attributes:@{ NSFilePosixPermissions : @(perms) }
                                      error:&e])
            NSLog(@"CrashReporter: cannot create %@: %@", dir, e);
    }
}

/* ------------------------------------------------------------------ */
/* Path resolution                                                     */
/* ------------------------------------------------------------------ */

- (NSString *)locateAnalyzer
{
    NSArray *candidates = @[
        @"gs-crash-analyzer",
        [[[NSProcessInfo processInfo] arguments][0]
            stringByDeletingLastPathComponent],
        @"/Developer/Library/Sources/gershwin-components/CrashReporter/Analyzer/obj/gs-crash-analyzer"
    ];
    for (NSString *c in candidates)
    {
        if ([c isEqualToString:@"gs-crash-analyzer"])
        {
            NSString *which = [self which:c];
            if (which != nil)
                return which;
            continue;
        }
        if ([_fm isExecutableFileAtPath:c])
            return c;
    }
    return nil;
}

- (NSString *)which:(NSString *)name
{
    NSTask *t = [[NSTask alloc] init];
    [t setLaunchPath:@"/bin/sh"];
    [t setArguments:@[ @"-c", [NSString stringWithFormat:@"command -v %@", name] ]];
    NSPipe *p = [NSPipe pipe];
    [t setStandardOutput:p];
    [t setStandardError:[NSPipe pipe]];
    @try { [t launch]; } @catch (NSException *e) { return nil; }
    [t waitUntilExit];
    if ([t terminationStatus] != 0)
        return nil;
    NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [s length] ? s : nil;
}

- (NSString *)crashDirForPid:(pid_t)pid appName:(NSString *)appName
{
    NSNumber *key = @(pid);
    NSString *existing = _pidToCrashDir[key];
    if (pid > 0 && existing != nil && [_fm fileExistsAtPath:existing])
        return existing;
    NSString *app = [appName lastPathComponent];
    if ([app length] == 0)
        app = @"Unknown";
    NSString *dir = GSCrashNewCrashDirectory(app, pid);
    if (pid > 0)
        _pidToCrashDir[key] = dir;
    return dir;
}

/* ------------------------------------------------------------------ */
/* Artifact movement                                                   */
/* ------------------------------------------------------------------ */

- (BOOL)moveItemFrom:(NSString *)src to:(NSString *)dst
{
    NSError *e = nil;
    if ([_fm moveItemAtPath:src toPath:dst error:&e])
        return YES;
    /* Cross-filesystem fallback: copy then remove the source. */
    if ([_fm copyItemAtPath:src toPath:dst error:&e])
    {
        [_fm removeItemAtPath:src error:nil];
        return YES;
    }
    NSLog(@"CrashReporter: cannot move %@ -> %@: %@", src, dst, e);
    return NO;
}

/* ------------------------------------------------------------------ */
/* Metadata                                                            */
/* ------------------------------------------------------------------ */

- (void)writeMetadataForEvent:(GSCrashEvent *)event
                         dir:(NSString *)dir
            detectionMethod:(NSString *)method
{
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    if (event.executable) meta[@"executable"] = event.executable;
    if (event.application) meta[@"application"] = event.application;
    if (event.version) meta[@"version"] = event.version;
    meta[@"pid"] = @(event.pid);
    if (event.signalName) meta[@"signal"] = event.signalName;
    if (event.exception) meta[@"exception"] = event.exception;
    if (event.reason) meta[@"reason"] = event.reason;
    if (event.buildID) meta[@"build_id"] = event.buildID;
    meta[@"uid"] = @(getuid());
    meta[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    meta[@"detection_method"] = method;
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:meta
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&e];
    if (d == nil)
    {
        NSLog(@"CrashReporter: cannot serialize metadata: %@", e);
        return;
    }
    NSString *path = [dir stringByAppendingPathComponent:GSCrashMetadataFile];
    if (![d writeToFile:path options:NSDataWritingAtomic error:&e])
        NSLog(@"CrashReporter: cannot write metadata: %@", e);
    else
        chmod([path fileSystemRepresentation], 0600);
}

/* Find and consume a marker file whose pid matches this event. */
- (NSDictionary *)consumeMarkerForPid:(pid_t)pid
{
    if (pid <= 0)
        return nil;
    for (NSString *name in [_fm contentsOfDirectoryAtPath:_markersDir error:nil])
    {
        if (![name hasSuffix:@".marker"])
            continue;
        NSString *path = [_markersDir stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil)
            continue;
        NSError *e = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
        if (![obj isKindOfClass:[NSDictionary class]])
            continue;
        NSDictionary *d = obj;
        pid_t mpid = 0;
        if ([d[GSCrashMarkerPIDKey] isKindOfClass:[NSNumber class]])
            mpid = [d[GSCrashMarkerPIDKey] intValue];
        if (mpid != pid)
            continue;
        /* Move to processed so the detector never re-emits it. */
        NSString *dst = [_processedMarkersDir stringByAppendingPathComponent:name];
        [self moveItemFrom:path to:dst];
        return d;
    }
    return nil;
}

- (void)mergeMarkerDict:(NSDictionary *)d intoReport:(GSCrashReport *)report
{
    if (d == nil)
        return;
    if (report.applicationName == nil || [report.applicationName length] == 0)
    {
        NSString *app = d[GSCrashMarkerAppKey];
        if ([app length])
            report.applicationName = app;
    }
    if (report.applicationVersion == nil)
    {
        NSString *v = d[GSCrashMarkerVersionKey];
        if ([v length])
            report.applicationVersion = v;
    }
    if (report.executablePath == nil)
    {
        NSString *exe = d[GSCrashMarkerExecKey];
        if ([exe length])
            report.executablePath = exe;
    }
    if (report.signal == nil)
    {
        NSString *s = d[GSCrashMarkerSignalKey];
        if ([s length])
            report.signal = s;
    }
    if (report.exceptionName == nil)
    {
        NSString *ex = d[GSCrashMarkerExceptionKey];
        if ([ex length])
            report.exceptionName = ex;
    }
    if (report.exceptionReason == nil)
    {
        NSString *r = d[GSCrashMarkerReasonKey];
        if ([r length])
            report.exceptionReason = r;
    }
    if (report.buildID == nil)
    {
        NSString *b = d[GSCrashMarkerBuildIDKey];
        if ([b length])
            report.buildID = b;
    }
}

/* ------------------------------------------------------------------ */
/* Core-availability reasoning (SPEC 8/28)                             */
/* ------------------------------------------------------------------ */

- (NSString *)coreUnavailableReason
{
    if (![_platform isCoreDumpingEnabled])
        return @"the current system core-size limit is zero.";
    NSString *collector = [_platform existingCrashCollector];
    if (collector != nil && ![collector isEqualToString:@"none"] &&
        ![collector isEqualToString:@"kernel"])
        return @"the system crash collector owns core-file processing.";
    return @"no core dump was produced.";
}

/* ------------------------------------------------------------------ */
/* Event processing                                                    */
/* ------------------------------------------------------------------ */

- (void)processEvent:(GSCrashEvent *)event
{
    if (![event isValid])
        return;

    if ([event.kind isEqualToString:@"core"])
        [self processCoreEvent:event];
    else
        [self processMarkerEvent:event];
}

- (void)processCoreEvent:(GSCrashEvent *)event
{
    NSString *appName = event.executable ?: @"Unknown";
    NSString *crashDir = [self crashDirForPid:event.pid appName:appName];
    if (crashDir == nil)
    {
        NSLog(@"CrashReporter: cannot create crash dir for %@ pid %d",
              appName, (int)event.pid);
        return;
    }

    NSString *coreDst = [crashDir stringByAppendingPathComponent:GSCrashCoreFile];
    BOOL movedCore = [self moveItemFrom:event.path to:coreDst];
    if (!movedCore)
        coreDst = event.path; /* keep raw data where it is rather than lose it */

    [self writeMetadataForEvent:event dir:crashDir detectionMethod:@"directory"];

    GSCrashReport *report = [GSCrashReport report];
    report.crashDirectory = crashDir;
    report.applicationName = [appName lastPathComponent];
    report.pid = event.pid;
    report.executablePath = event.executable;
    report.uid = getuid();
    report.detectionMethod = @"directory";
    report.collector = [_platform existingCrashCollector] ?: @"GNUstep";
    report.coreAvailable = [_fm fileExistsAtPath:coreDst];
    report.coreDumpPath = GSCrashCoreFile;
    if (report.coreAvailable)
    {
        struct stat st;
        if (stat([coreDst fileSystemRepresentation], &st) == 0)
            report.coreDumpSize = (long long)st.st_size;
    }

    /* Correlate (SPEC 14): fold the matching marker into the same report. */
    NSDictionary *marker = [self consumeMarkerForPid:event.pid];
    [self mergeMarkerDict:marker intoReport:report];

    [report writeToDirectory:crashDir];

    [NSThread detachNewThreadSelector:@selector(runAnalyzerForDir:)
                             toTarget:self
                           withObject:crashDir];
}

- (void)processMarkerEvent:(GSCrashEvent *)event
{
    /* If a core already created a dir for this pid, merge into it instead. */
    NSString *crashDir = [self crashDirForPid:event.pid appName:event.application];
    if (crashDir == nil)
    {
        NSLog(@"CrashReporter: cannot create crash dir for marker pid %d",
              (int)event.pid);
        return;
    }

    [self writeMetadataForEvent:event dir:crashDir detectionMethod:@"marker"];

    GSCrashReport *report = [GSCrashReport report];
    report.crashDirectory = crashDir;
    report.applicationName = event.application ?: @"Unknown";
    report.applicationVersion = event.version;
    report.pid = event.pid;
    report.executablePath = event.executable;
    report.uid = (event.uid != 0) ? event.uid : getuid();
    report.signal = event.signalName;
    report.exceptionName = event.exception;
    report.exceptionReason = event.reason;
    report.buildID = event.buildID;
    report.detectionMethod = @"marker";
    report.collector = [_platform existingCrashCollector] ?: @"GNUstep";
    report.coreAvailable = NO;
    report.coreUnavailableReason = [self coreUnavailableReason];

    [report writeToDirectory:crashDir];

    /* The marker itself is consumed by writeMetadata's directory placement
     * is not enough; move it to processed so it is never re-emitted. */
    NSString *src = event.path;
    if ([_fm fileExistsAtPath:src])
    {
        NSString *dst = [_processedMarkersDir
            stringByAppendingPathComponent:[src lastPathComponent]];
        [self moveItemFrom:src to:dst];
    }

    [NSThread detachNewThreadSelector:@selector(runAnalyzerForDir:)
                             toTarget:self
                           withObject:crashDir];
}

/* ------------------------------------------------------------------ */
/* Analyzer invocation (SPEC 15/28/29)                                 */
/* ------------------------------------------------------------------ */

- (void)runAnalyzerForDir:(NSString *)dir
{
    @autoreleasepool
    {
        NSString *analyzer = [self locateAnalyzer];
        if (analyzer == nil)
        {
            NSLog(@"CrashReporter: gs-crash-analyzer not found; "
                  @"raw crash data remains at %@", dir);
        }
        else
        {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:analyzer];
            NSMutableArray *args = [NSMutableArray arrayWithObject:dir];
            NSString *core = [dir stringByAppendingPathComponent:GSCrashCoreFile];
            if ([_fm fileExistsAtPath:core])
            {
                [args addObject:@"--core"];
                [args addObject:core];
            }
            [args addObject:@"--timeout"];
            [args addObject:@"90"];
            [task setArguments:args];
            [task setStandardOutput:[NSPipe pipe]];
            [task setStandardError:[NSPipe pipe]];

            @try { [task launch]; }
            @catch (NSException *e)
            {
                NSLog(@"CrashReporter: failed to launch analyzer: %@", e);
                [self finishWithReportAtDir:dir];
                return;
            }

            /* Watchdog: never let a pathological core hang crashd (SPEC 28). */
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90.0];
            while ([task isRunning] && [deadline timeIntervalSinceNow] > 0)
                [NSThread sleepForTimeInterval:0.25];
            if ([task isRunning])
            {
                NSLog(@"CrashReporter: analyzer overran 90s; terminating");
                [task terminate];
            }
            [task waitUntilExit];
        }
        [self finishWithReportAtDir:dir];
    }
}

- (void)finishWithReportAtDir:(NSString *)dir
{
    GSCrashReport *report = [GSCrashReport reportFromDirectory:dir];
    if (report == nil)
        report = [GSCrashReport report];
    report.crashDirectory = dir;

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:GSCrashNotificationName
                      object:nil
                    userInfo:@{ GSCrashNotificationCrashDirKey : dir }
           deliverImmediately:YES];

    /* Durable pending marker so ctl/GUI can list crashes even if the
     * distributed notification was missed. */
    NSString *leaf = [dir lastPathComponent];
    NSString *pendingPath = [_pendingDir stringByAppendingPathComponent:
        [leaf stringByAppendingPathExtension:@"json"]];
    NSDictionary *pend = @{
        @"crashDirectory" : dir,
        @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    };
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:pend options:0 error:&e];
    if (d != nil)
        [d writeToFile:pendingPath options:NSDataWritingAtomic error:nil];
    chmod([pendingPath fileSystemRepresentation], 0600);

    NSLog(@"CrashReporter: crash reported at %@ (app=%@ core=%@)",
          dir, report.applicationName ?: @"?",
          report.coreAvailable ? @"yes" : @"no");
}

@end
