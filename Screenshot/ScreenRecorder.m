/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ScreenRecorder.h"
#include <sys/utsname.h>

@implementation ScreenRecorder

+ (NSString *)ffmpegPath
{
    NSString *searchPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
    for (NSString *dir in [searchPath componentsSeparatedByString:@":"]) {
        NSString *path = [dir stringByAppendingPathComponent:@"ffmpeg"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path])
            return path;
    }
    return nil;
}

- (id)initWithOptions:(ScreenRecordingOptions *)someOptions
                 area:(NSRect)anArea
             delegate:(id<ScreenRecorderDelegate>)aDelegate
{
    self = [super init];
    if (self) {
        options = [someOptions copy];
        area = anArea;
        delegate = aDelegate;
        errors = [[NSMutableData alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [options release];
    [ffmpeg release];
    [directory release];
    [recordingPath release];
    [outputPath release];
    [task release];
    [input release];
    [errors release];
    [startDate release];
    [super dealloc];
}

- (NSString *)systemName
{
    struct utsname name;
    if (uname(&name) != 0)
        return @"";
    return [NSString stringWithUTF8String:name.sysname];
}

- (BOOL)launchWithArguments:(NSArray *)arguments
               keepingInput:(BOOL)keepInput
                     error:(NSString **)message
{
    NSPipe *errorPipe = [NSPipe pipe];
    NSTask *newTask = [[NSTask alloc] init];

    [newTask setLaunchPath:ffmpeg];
    [newTask setArguments:arguments];
    [newTask setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [newTask setStandardError:errorPipe];
    if (keepInput) {
        NSPipe *inputPipe = [NSPipe pipe];
        [newTask setStandardInput:inputPipe];
        [input release];
        input = [[inputPipe fileHandleForWriting] retain];
    } else {
        [newTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    }

    [errors setLength:0];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(errorsAvailable:)
                                                 name:NSFileHandleReadCompletionNotification
                                               object:[errorPipe fileHandleForReading]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(taskDidTerminate:)
                                                 name:NSTaskDidTerminateNotification
                                               object:newTask];
    @try {
        [newTask launch];
    } @catch (NSException *exception) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [newTask release];
        if (message)
            *message = [exception reason];
        return NO;
    }
    [[errorPipe fileHandleForReading] readInBackgroundAndNotify];
    [task release];
    task = newTask;
    return YES;
}

- (BOOL)startReturningError:(NSString **)message
{
    ffmpeg = [[ScreenRecorder ffmpegPath] retain];
    if (!ffmpeg) {
        if (message)
            *message = NSLocalizedString(@"Screen recording needs ffmpeg, which is not installed.", @"");
        return NO;
    }

    NSString *display = [[[NSProcessInfo processInfo] environment] objectForKey:@"DISPLAY"];
    if ([display length] == 0) {
        if (message)
            *message = NSLocalizedString(@"There is no X display to record.", @"");
        return NO;
    }

    directory = [[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ScreenRecording-%@",
         [[NSProcessInfo processInfo] globallyUniqueString]]] retain];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:NULL]) {
        if (message)
            *message = NSLocalizedString(@"A temporary folder for the recording could not be made.", @"");
        return NO;
    }

    NSString *extension = [options fileExtension];
    outputPath = [[directory stringByAppendingPathComponent:
        [@"recording" stringByAppendingPathExtension:extension]] retain];
    recordingPath = [([options needsConversion]
                      ? [directory stringByAppendingPathComponent:@"recording-lossless.mkv"]
                      : outputPath) retain];

    NSArray *arguments = [options recordingArgumentsForArea:area
                                                     display:display
                                                  soundInput:[ScreenRecordingOptions
                                                              soundInputArgumentsForSystem:[self systemName]]
                                                      output:recordingPath];
    if (![self launchWithArguments:arguments keepingInput:YES error:message])
        return NO;
    startDate = [[NSDate alloc] init];
    return YES;
}

- (void)stop
{
    if (stopping || ![task isRunning])
        return;
    stopping = YES;
    @try {
        [input writeData:[@"q" dataUsingEncoding:NSASCIIStringEncoding]];
        [input closeFile];
    } @catch (NSException *exception) {
        // ffmpeg went away on its own; its termination says how it went
    }
}

- (void)cancel
{
    delegate = nil;
    stopping = YES;
    if ([task isRunning])
        [task terminate];
    [self discardFile];
}

- (BOOL)isRecording
{
    return startDate != nil && !stopping && [task isRunning];
}

- (NSTimeInterval)elapsedTime
{
    return startDate ? -[startDate timeIntervalSinceNow] : 0;
}

- (void)discardFile
{
    if (directory)
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

- (void)errorsAvailable:(NSNotification *)notification
{
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] == 0)
        return;
    [errors appendData:data];
    [[notification object] readInBackgroundAndNotify];
}

- (NSString *)errorText
{
    NSString *text = [[[NSString alloc] initWithData:errors encoding:NSUTF8StringEncoding] autorelease];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0)
        return NSLocalizedString(@"ffmpeg stopped without saying why.", @"");
    return text;
}

- (void)taskDidTerminate:(NSNotification *)notification
{
    int status = [task terminationStatus];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:task];
    if (!delegate)
        return;

    BOOL written = [[NSFileManager defaultManager] fileExistsAtPath:(converting ? outputPath : recordingPath)];
    if (status != 0 || !written || (!stopping && !converting)) {
        // A recording that ends before it was asked to failed, whatever
        // ffmpeg's exit code says
        [self discardFile];
        [delegate screenRecorder:self didFailWithMessage:[self errorText]];
        return;
    }

    if (!converting && [options needsConversion]) {
        NSString *message = nil;
        converting = YES;
        [delegate screenRecorderIsConverting:self];
        if (![self launchWithArguments:[options conversionArgumentsFrom:recordingPath to:outputPath]
                          keepingInput:NO
                                 error:&message]) {
            [self discardFile];
            [delegate screenRecorder:self didFailWithMessage:message];
        }
        return;
    }

    if (![recordingPath isEqualToString:outputPath])
        [[NSFileManager defaultManager] removeItemAtPath:recordingPath error:NULL];
    [delegate screenRecorder:self didFinishWithFile:outputPath];
}

@end
