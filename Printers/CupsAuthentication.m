/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CupsAuthentication.h"
#include <cups/cups.h>

@implementation CupsAuthentication

+ (NSString *)passwordFromHelper:(NSString *)helperPath prompt:(NSString *)prompt
{
    if (helperPath == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:helperPath]) {
        return nil;
    }
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *output = [NSPipe pipe];
    [task setLaunchPath:helperPath];
    [task setArguments:@[prompt]];
    [task setStandardOutput:output];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        NSLog(@"CupsAuthentication: could not start %@: %@", helperPath, exception);
        return nil;
    }
    NSData *data = [[output fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if ([task terminationStatus] != 0) {
        return nil;
    }
    NSString *answer = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSRange newline = [answer rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
        answer = [answer substringToIndex:newline.location];
    }
    return [answer length] > 0 ? answer : nil;
}

static const char *AskPassword(const char *prompt, http_t *http, const char *method,
                               const char *resource, void *userData)
{
    (void)prompt; (void)http; (void)method; (void)resource; (void)userData;
    static char password[256];
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSString *helper = [[[NSProcessInfo processInfo] environment] objectForKey:@"SUDO_ASKPASS"];
    NSString *answer = [CupsAuthentication passwordFromHelper:helper
        prompt:@"Enter your password to change printer settings."];
    const char *result = NULL;
    if (answer != nil && [answer lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < sizeof(password)) {
        strlcpy(password, [answer UTF8String], sizeof(password));
        result = password;
    }
    [pool release];
    return result;
}

+ (void)install
{
    cupsSetPasswordCB2(AskPassword, NULL);
}

@end
