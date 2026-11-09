/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSCrashDetector.h"
#import "GSCrashConstants.h"
#import <sys/stat.h>
#import <unistd.h>

@implementation GSCrashEvent

- (BOOL)isValid
{
    if (![_kind isEqualToString:@"core"] && ![_kind isEqualToString:@"marker"])
        return NO;
    if ([_path length] == 0)
        return NO;
    return YES;
}

@end

@interface GSCrashDetector ()
{
    NSString *_inboxDir;
    NSString *_markersDir;
    id<GSCrashPlatform> _platform;
    NSFileManager *_fm;
    /* path -> last observed size (NSNumber). */
    NSMutableDictionary *_stable;
    /* paths already emitted, so we never process the same event twice. */
    NSMutableSet *_emitted;
}
@end

@implementation GSCrashDetector

- (instancetype)initWithInbox:(NSString *)inboxDir
                      markers:(NSString *)markersDir
                     platform:(id<GSCrashPlatform>)platform
{
    self = [super init];
    if (self)
    {
        _inboxDir = [inboxDir copy];
        _markersDir = [markersDir copy];
        _platform = platform;
        _fm = [NSFileManager defaultManager];
        _stable = [NSMutableDictionary dictionary];
        _emitted = [NSMutableSet set];
    }
    return self;
}

/* Parse a core filename of the form core.<exe>.<pid> (our core_pattern). */
- (BOOL)parseCoreName:(NSString *)name
                  pid:(pid_t *)outPid
             executable:(NSString **)outExe
{
    if (![name hasPrefix:@"core"])
        return NO;
    NSArray *parts = [name componentsSeparatedByString:@"."];
    if ([parts count] < 3)
        return NO;
    if (![parts[0] isEqualToString:@"core"])
        return NO;
    NSString *pidStr = [parts lastObject];
    if ([pidStr length] == 0)
        return NO;
    /* Reject anything that is not a plain decimal pid. */
    for (NSUInteger i = 0; i < [pidStr length]; i++)
    {
        unichar c = [pidStr characterAtIndex:i];
        if (c < '0' || c > '9')
            return NO;
    }
    pid_t pid = (pid_t)[pidStr intValue];
    if (pid <= 0)
        return NO;
    NSMutableString *exe = [NSMutableString string];
    for (NSUInteger i = 1; i + 1 < [parts count]; i++)
    {
        if ([exe length])
            [exe appendString:@"."];
        [exe appendString:parts[i]];
    }
    if ([exe length] == 0)
        return NO;
    *outPid = pid;
    *outExe = exe;
    return YES;
}

/* Cheap gdb probe to learn pid + executable from a core with no name info. */
- (BOOL)probeCoreWithGdb:(NSString *)corePath
                 outPid:(pid_t *)outPid
              outExec:(NSString **)outExe
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/gdb"];
    [task setArguments:@[ @"-batch", @"-ex", @"info proc", @"-c", corePath ]];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];
    @try
    {
        [task launch];
    }
    @catch (NSException *e)
    {
        return NO;
    }
    [task waitUntilExit];
    if ([task terminationStatus] != 0)
        return NO;
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *txt = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
    if ([txt length] == 0)
        return NO;
    pid_t pid = 0;
    NSString *exe = nil;
    for (NSString *line in [txt componentsSeparatedByString:@"\n"])
    {
        NSString *l = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (pid == 0)
        {
            /* gdb prints "process 1234" on some builds, or "[New LWP 1234]"
             * where the first LWP equals the process pid on Linux. */
            NSRange r = [l rangeOfString:@"process "];
            if (r.location != NSNotFound)
            {
                NSString *num = [[l substringFromIndex:NSMaxRange(r)]
                    stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                pid = (pid_t)[num intValue];
            }
            if (pid == 0)
            {
                NSRange lr = [l rangeOfString:@"[New LWP "];
                if (lr.location != NSNotFound)
                {
                    NSString *num = [l substringFromIndex:NSMaxRange(lr)];
                    num = [num stringByTrimmingCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@"]"]];
                    pid = (pid_t)[num intValue];
                }
            }
        }
        if (exe == nil)
        {
            NSRange r = [l rangeOfString:@"exe = "];
            if (r.location != NSNotFound)
            {
                NSString *v = [l substringFromIndex:NSMaxRange(r)];
                v = [v stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([v hasPrefix:@"'"] && [v hasSuffix:@"'"] && [v length] >= 2)
                    v = [v substringWithRange:NSMakeRange(1, [v length] - 2)];
                if ([v length])
                    exe = v;
            }
        }
    }
    if (pid <= 0)
        return NO;
    *outPid = pid;
    *outExe = exe;
    return YES;
}

- (GSCrashEvent *)eventForCoreAtPath:(NSString *)path
{
    NSString *name = [path lastPathComponent];
    pid_t pid = 0;
    NSString *exe = nil;
    if ([self parseCoreName:name pid:&pid executable:&exe])
    {
        /* good, derived from filename */
    }
    else if (![self probeCoreWithGdb:path outPid:&pid outExec:&exe])
    {
        /* Without gdb or a usable name we cannot correlate; still collect. */
        pid = 0;
        exe = nil;
    }
    GSCrashEvent *ev = [[GSCrashEvent alloc] init];
    ev.kind = @"core";
    ev.path = path;
    ev.pid = pid;
    ev.executable = exe;
    return ev;
}

- (GSCrashEvent *)eventForMarkerAtPath:(NSString *)path
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil)
        return nil;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (obj == nil || ![obj isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary *d = obj;
    GSCrashEvent *ev = [[GSCrashEvent alloc] init];
    ev.kind = @"marker";
    ev.path = path;
    ev.application = d[GSCrashMarkerAppKey];
    ev.version = d[GSCrashMarkerVersionKey];
    ev.executable = d[GSCrashMarkerExecKey];
    ev.signalName = d[GSCrashMarkerSignalKey];
    ev.exception = d[GSCrashMarkerExceptionKey];
    ev.reason = d[GSCrashMarkerReasonKey];
    ev.buildID = d[GSCrashMarkerBuildIDKey];
    if ([d[GSCrashMarkerPIDKey] isKindOfClass:[NSNumber class]])
        ev.pid = [d[GSCrashMarkerPIDKey] intValue];
    if ([d[GSCrashMarkerUIDKey] isKindOfClass:[NSNumber class]])
        ev.uid = [d[GSCrashMarkerUIDKey] unsignedIntValue];
    return ev;
}

/*
 * One scan pass. A file is reported only when its size matches the previous
 * scan (stable) and it has not been emitted before. Returns the new events and
 * records them as emitted so they are never reported twice.
 */
- (NSArray<GSCrashEvent *> *)scan
{
    NSMutableArray *events = [NSMutableArray array];
    NSMutableDictionary *current = [NSMutableDictionary dictionary];

    /* Method A: core inbox. */
    for (NSString *name in [_fm contentsOfDirectoryAtPath:_inboxDir error:nil])
    {
        if (![name hasPrefix:@"core"])
            continue;
        NSString *path = [_inboxDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [_fm attributesOfItemAtPath:path error:nil];
        if (attrs == nil)
            continue;
        if (![[attrs fileType] isEqualToString:NSFileTypeRegular])
            continue;
        long long size = [attrs fileSize];
        NSNumber *prev = _stable[path];
        if (prev != nil && [prev longLongValue] == size &&
            ![_emitted containsObject:path])
        {
            GSCrashEvent *ev = [self eventForCoreAtPath:path];
            if ([ev isValid])
            {
                [events addObject:ev];
                [_emitted addObject:path];
            }
        }
        current[path] = @(size);
    }

    /* Method C: application markers. */
    for (NSString *name in [_fm contentsOfDirectoryAtPath:_markersDir error:nil])
    {
        if (![name hasSuffix:@".marker"])
            continue;
        NSString *path = [_markersDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [_fm attributesOfItemAtPath:path error:nil];
        if (attrs == nil)
            continue;
        if (![[attrs fileType] isEqualToString:NSFileTypeRegular])
            continue;
        long long size = [attrs fileSize];
        NSNumber *prev = _stable[path];
        if (prev != nil && [prev longLongValue] == size &&
            ![_emitted containsObject:path])
        {
            GSCrashEvent *ev = [self eventForMarkerAtPath:path];
            if ([ev isValid])
            {
                [events addObject:ev];
                [_emitted addObject:path];
            }
        }
        current[path] = @(size);
    }

    _stable = current;
    return events;
}

@end
