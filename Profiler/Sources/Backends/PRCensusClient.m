/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PRCensusClient.h"
#import "PRCensus.h"
#import "PRRecorder.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

@implementation PRCensusClient

+ (NSString *)libraryPath
{
    /* The library is installed beside the other system libraries, and the
       program under test loads it by absolute path. */
    NSArray *directories = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSSystemDomainMask, YES);
    if ([directories count] == 0)
        return nil;
    return [[directories objectAtIndex:0]
            stringByAppendingPathComponent:@"Libraries/libPRCensus.so"];
}

+ (BOOL)isLibraryInstalled
{
    NSString *path = [self libraryPath];
    return path != nil &&
           [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (int)processIdentifier
{
    return _task != nil ? [_task processIdentifier] : 0;
}

- (BOOL)failWithMessage:(NSString *)message error:(NSError **)error
{
    if (error != NULL)
        *error = [NSError errorWithDomain:PRErrorDomain
                                     code:10
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

- (BOOL)startProgram:(NSString *)path
           arguments:(NSArray *)arguments
               error:(NSError **)error
{
    NSString *library = [PRCensusClient libraryPath];
    if (![PRCensusClient isLibraryInstalled])
        return [self failWithMessage:
                [NSString stringWithFormat:@"The counting library is not "
                 @"installed at %@, so no program can be watched.", library]
                               error:error];

    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path])
        return [self failWithMessage:
                [NSString stringWithFormat:@"%@ cannot be started.", path]
                               error:error];

    _socketDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"PRCensus-%d-%.0f",
                         (int)getpid(), [NSDate timeIntervalSinceReferenceDate]]];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_socketDirectory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:NULL])
        return [self failWithMessage:@"No place to talk to the program."
                               error:error];

    NSString *stem = [_socketDirectory stringByAppendingPathComponent:@"census"];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment]
                                        mutableCopy];
    [environment setObject:library forKey:@"LD_PRELOAD"];
    [environment setObject:stem forKey:@"PR_CENSUS_SOCKET"];

    _task = [[NSTask alloc] init];
    [_task setLaunchPath:path];
    [_task setArguments:arguments ? arguments : @[]];
    [_task setEnvironment:environment];

    @try {
        [_task launch];
    } @catch (NSException *exception) {
        _task = nil;
        return [self failWithMessage:
                [NSString stringWithFormat:@"%@ could not be started: %@",
                 [path lastPathComponent], [exception reason]] error:error];
    }

    /* The program's helpers get the same environment, so every process
       answers under its own name and only the one we started is ours. */
    _socketPath = [NSString stringWithFormat:@"%@.%d", stem,
                   [_task processIdentifier]];
    return YES;
}

- (BOOL)isRunning
{
    return _task != nil && [_task isRunning];
}

/* Talking to the program is a question and an answer on a socket of its
   own, so a program too busy to serve its usual connections still answers. */
- (NSString *)ask:(NSString *)command error:(NSError **)error
{
    struct sockaddr_un address;
    struct timeval timeout;
    int fd;

    if (_socketPath == nil ||
        [_socketPath length] >= sizeof(address.sun_path)) {
        [self failWithMessage:@"No program is being watched." error:error];
        return nil;
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        [self failWithMessage:@"No socket could be opened." error:error];
        return nil;
    }

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, [_socketPath fileSystemRepresentation],
            sizeof(address.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        [self failWithMessage:
         @"The program does not answer. It may not have started yet, or it "
         @"is not an Objective-C program." error:error];
        return nil;
    }

    /* Nothing here may hang the interface if the program stops answering. */
    timeout.tv_sec = 2;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    const char *request = [command UTF8String];
    if (write(fd, request, strlen(request)) < 0) {
        close(fd);
        [self failWithMessage:@"The program stopped listening." error:error];
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    char buffer[8192];
    for (;;) {
        ssize_t got = read(fd, buffer, sizeof(buffer));
        if (got < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (got == 0)
            break;
        [data appendBytes:buffer length:(NSUInteger)got];

        /* The answer ends with a full stop on a line of its own. */
        NSUInteger length = [data length];
        if (length >= 2) {
            const char *bytes = [data bytes];
            if (bytes[length - 2] == '.' && bytes[length - 1] == '\n')
                break;
        }
    }
    close(fd);

    NSString *answer = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
    if (answer == nil) {
        [self failWithMessage:@"The program's answer could not be read."
                        error:error];
        return nil;
    }
    return answer;
}

- (PRCensusSnapshot *)takeSnapshotWithError:(NSError **)error
{
    if (![self isRunning]) {
        [self failWithMessage:@"The program has ended." error:error];
        return nil;
    }

    NSString *answer = [self ask:@"census\n" error:error];
    if (answer == nil)
        return nil;

    if ([answer hasPrefix:@"error"]) {
        [self failWithMessage:[answer substringFromIndex:6] error:error];
        return nil;
    }
    return [PRCensusSnapshot snapshotFromText:answer];
}

- (void)stop
{
    if ([self isRunning])
        [_task terminate];
    _task = nil;

    if (_socketDirectory != nil) {
        [[NSFileManager defaultManager] removeItemAtPath:_socketDirectory
                                                   error:NULL];
        _socketDirectory = nil;
        _socketPath = nil;
    }
}

@end
