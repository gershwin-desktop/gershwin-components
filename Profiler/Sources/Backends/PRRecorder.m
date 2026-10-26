/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRRecorder.h"
#import "PRRecorderPrivate.h"
#import "PRPrivilegedTask.h"
#import "PRProfile.h"
#import "PRStackParser.h"
#include <signal.h>

NSString * const PRErrorDomain = @"io.github.gershwin-desktop.Profiler";

@implementation PRRecordRequest

- (id)init
{
    self = [super init];
    if (self == nil)
        return nil;
    _frequency = 999;
    _callGraph = PRCallGraphDwarf;
    _mode = PRProfileModeCPU;
    _memoryCost = PRMemoryCostPeak;
    return self;
}

- (BOOL)isAttach
{
    return _pid > 0;
}

@end

@implementation PRRecorder

@synthesize isRecording = _recording;
@synthesize request = _request;

+ (NSString *)toolName
{
    return nil;
}

+ (NSString *)toolPath
{
    return [PRToolLocator pathForTool:[self toolName]];
}

+ (BOOL)supportsMode:(PRProfileMode)mode
{
    (void)mode;
    return NO;
}

+ (NSString *)packageName
{
    return [self toolName];
}

+ (NSString *)warningForRequest:(PRRecordRequest *)request
{
    (void)request;
    return nil;
}

- (BOOL)startWithRequest:(PRRecordRequest *)request error:(NSError **)error
{
    _request = request;
    _cancelled = NO;

    NSString *template = [NSString stringWithFormat:@"Profiler-%d-%.0f",
                          (int)getpid(), [NSDate timeIntervalSinceReferenceDate]];
    _workDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:template];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_workDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error])
        return NO;

    _logPath = [_workDirectory stringByAppendingPathComponent:@"tool.log"];
    [[NSFileManager defaultManager] createFileAtPath:_logPath
                                            contents:[NSData data]
                                          attributes:nil];

    if (![self launchRecordTaskWithError:error])
        return NO;

    _recording = YES;
    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(recordTaskDidTerminate:)
            name:NSTaskDidTerminateNotification
          object:_recordTask];

    if ([request duration] > 0)
        _durationTimer = [NSTimer scheduledTimerWithTimeInterval:[request duration]
                                                          target:self
                                                        selector:@selector(durationElapsed:)
                                                        userInfo:nil
                                                         repeats:NO];
    return YES;
}

- (void)durationElapsed:(NSTimer *)timer
{
    (void)timer;
    _durationTimer = nil;
    [self stopRecording];
}

- (void)stopRecording
{
    if (!_recording)
        return;

    [_durationTimer invalidate];
    _durationTimer = nil;
    _recording = NO;
    [self reportStatus:@"Finishing the recording..."];

    if (_recordTask == nil || ![_recordTask isRunning]) {
        [self recordTaskDidTerminate:nil];
        return;
    }

    /* The tool runs as root, so it can only be signalled through sudo; an
       interrupt makes perf and heaptrack write out their data and exit. */
    if ([self recordNeedsElevation] && ![PRPrivilegedTask isRoot]) {
        NSString *kill = [PRToolLocator pathForTool:@"kill"];
        [PRPrivilegedTask runTool:kill
                        arguments:@[@"-INT",
                                    [NSString stringWithFormat:@"%d",
                                     [_recordTask processIdentifier]]]
                         elevated:YES];
    } else {
        kill([_recordTask processIdentifier], SIGINT);
    }
}

- (void)cancel
{
    _cancelled = YES;
    [_durationTimer invalidate];
    _durationTimer = nil;
    if (_recording)
        [self stopRecording];
    _recording = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)recordTaskDidTerminate:(NSNotification *)notification
{
    (void)notification;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_recordTask];
    _recording = NO;
    if (_cancelled)
        return;

    /* Data written by the elevated tool belongs to root; taking ownership
       lets the analysis step run as the user. */
    if ([self recordNeedsElevation] && ![PRPrivilegedTask isRoot] &&
        _dataPath != nil) {
        NSString *chown = [PRToolLocator pathForTool:@"chown"];
        [PRPrivilegedTask runTool:chown
                        arguments:@[[NSString stringWithFormat:@"%d:%d",
                                     (int)getuid(), (int)getgid()],
                                    _dataPath]
                         elevated:YES];
    }

    [self beginAnalysis];
}

- (BOOL)reanalyzeWithMemoryCost:(PRMemoryCost)cost
{
    (void)cost;
    return NO;
}

/* Subclass hooks. */

- (BOOL)launchRecordTaskWithError:(NSError **)error
{
    [self failWithMessage:@"This recorder is not implemented." error:error];
    return NO;
}

- (BOOL)recordNeedsElevation
{
    return NO;
}

- (PRProfile *)analyzeWithError:(NSError **)error
{
    [self failWithMessage:@"This recorder cannot analyse data." error:error];
    return nil;
}

/* Shared machinery. */

- (void)beginAnalysis
{
    if (_analyzing)
        return;
    _analyzing = YES;
    [self reportStatus:@"Reading the recorded stacks..."];
    [NSThread detachNewThreadSelector:@selector(analysisThread:)
                             toTarget:self
                           withObject:nil];
}

- (void)analysisThread:(id)ignored
{
    (void)ignored;
    @autoreleasepool {
        NSError *error = nil;
        PRProfile *profile = [self analyzeWithError:&error];
        NSArray *result = @[profile ? (id)profile : (id)[NSNull null],
                            error ? (id)error : (id)[NSNull null]];
        [self performSelectorOnMainThread:@selector(deliverResult:)
                               withObject:result
                            waitUntilDone:NO];
    }
}

- (void)deliverResult:(NSArray *)result
{
    _analyzing = NO;
    if (_cancelled)
        return;

    id profile = [result objectAtIndex:0];
    id error = [result objectAtIndex:1];
    [[self delegate] recorder:self
         didFinishWithProfile:(profile == [NSNull null] ? nil : profile)
                        error:(error == [NSNull null] ? nil : error)];
}

- (void)reportStatus:(NSString *)status
{
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(reportStatus:)
                               withObject:status
                            waitUntilDone:NO];
        return;
    }
    [[self delegate] recorder:self didReportStatus:status];
}

- (BOOL)failWithMessage:(NSString *)message error:(NSError **)error
{
    if (error != NULL)
        *error = [NSError errorWithDomain:PRErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

- (NSString *)toolLog
{
    NSString *log = [NSString stringWithContentsOfFile:_logPath
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    return log ? [log stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
}

- (NSFileHandle *)logFileHandle
{
    return [NSFileHandle fileHandleForWritingAtPath:_logPath];
}

- (BOOL)runTool:(NSString *)toolPath
      arguments:(NSArray *)arguments
       elevated:(BOOL)elevated
     lineHandler:(void (^)(NSString *line))lineHandler
          error:(NSError **)error
{
    NSTask *task = [PRPrivilegedTask taskForTool:toolPath
                                       arguments:arguments
                                        elevated:elevated];
    if (task == nil)
        return [self failWithMessage:@"sudo is not available." error:error];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[self logFileHandle]];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return [self failWithMessage:
                [NSString stringWithFormat:@"Could not run %@: %@",
                 [toolPath lastPathComponent], [exception reason]]
                               error:error];
    }

    NSFileHandle *handle = [pipe fileHandleForReading];
    NSMutableData *buffer = [NSMutableData data];

    while (!_cancelled) {
        NSData *chunk = [handle availableData];
        if ([chunk length] == 0)
            break;
        [buffer appendData:chunk];

        const char *bytes = (const char *)[buffer bytes];
        NSUInteger length = [buffer length];
        NSUInteger lineStart = 0;

        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] != '\n')
                continue;
            NSString *line = [[NSString alloc]
                              initWithBytes:bytes + lineStart
                                     length:i - lineStart
                                   encoding:NSUTF8StringEncoding];
            if (line != nil)
                lineHandler(line);
            lineStart = i + 1;
        }
        if (lineStart > 0) {
            [buffer replaceBytesInRange:NSMakeRange(0, lineStart)
                              withBytes:NULL
                                 length:0];
        }
    }

    if ([buffer length] > 0) {
        NSString *line = [[NSString alloc] initWithData:buffer
                                               encoding:NSUTF8StringEncoding];
        if ([line length] > 0)
            lineHandler(line);
    }

    [task waitUntilExit];
    if ([task terminationStatus] != 0 && !_cancelled) {
        NSString *log = [self toolLog];
        return [self failWithMessage:
                [NSString stringWithFormat:@"%@ failed.%@%@",
                 [toolPath lastPathComponent],
                 [log length] ? @"\n\n" : @"", log]
                               error:error];
    }
    return YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_durationTimer invalidate];
    if (_workDirectory != nil)
        [[NSFileManager defaultManager] removeItemAtPath:_workDirectory error:NULL];
}

@end
