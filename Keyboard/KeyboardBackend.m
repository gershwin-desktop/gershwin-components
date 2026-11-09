/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "KeyboardBackend.h"

static NSString *const kSetxkbmapLocal = @"/usr/local/bin/setxkbmap";
static NSString *const kSetxkbmapSystem = @"/usr/bin/setxkbmap";

@implementation KeyboardBackend

+ (NSString *)findSetxkbmap
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in @[kSetxkbmapLocal, kSetxkbmapSystem]) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:@[@"setxkbmap"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    NSString *trim = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] > 0 && [fm isExecutableFileAtPath:trim]) {
        return trim;
    }

    return nil;
}

+ (NSString *)trimmed:(NSString *)value
{
    if (!value) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)applyLayout:(NSString *)layout
            variant:(NSString *)variant
            options:(NSString *)options
          setxkbmap:(NSString *)setxkbmapPath
              error:(NSString **)error
{
    if (!setxkbmapPath) {
        if (error) {
            *error = @"setxkbmap not found";
        }
        return NO;
    }

    NSString *trimmedLayout = [self trimmed:layout];
    NSString *trimmedVariant = [self trimmed:variant];
    NSString *trimmedOptions = [self trimmed:options];

    NSTask *clearTask = [[NSTask alloc] init];
    [clearTask setLaunchPath:setxkbmapPath];
    [clearTask setArguments:@[@"-option", @""]];
    [clearTask launch];
    [clearTask waitUntilExit];

    NSMutableArray *args = [NSMutableArray array];
    if ([trimmedLayout length]) {
        [args addObject:@"-layout"];
        [args addObject:trimmedLayout];
    }

    if ([trimmedVariant length]) {
        [args addObject:@"-variant"];
        [args addObject:trimmedVariant];
    }

    if ([trimmedOptions length]) {
        [args addObject:@"-option"];
        [args addObject:trimmedOptions];
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:setxkbmapPath];
    [task setArguments:args];

    NSPipe *stderrPipe = [NSPipe pipe];
    [task setStandardError:stderrPipe];

    [task launch];
    // Drain stderr before waitUntilExit to avoid pipe-buffer deadlock
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if ([task terminationStatus] != 0) {
        NSString *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = (stderrString.length ? stderrString : @"Failed to run setxkbmap");
        }
        return NO;
    }
    return YES;
}

+ (BOOL)needsAppleISOKeySwapForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    return isApple && [keyboardType isEqualToString:@"ISO"];
}

+ (BOOL)applyAppleISOKeySwap
{
    NSTask *xmodmapTask = [[NSTask alloc] init];
    [xmodmapTask setLaunchPath:@"/usr/bin/xmodmap"];
    [xmodmapTask setArguments:@[
        @"-e", @"keycode 49 = less greater less greater bar dagger bar",
        @"-e", @"keycode 94 = asciicircum degree asciicircum degree notsign notsign notsign",
    ]];
    [xmodmapTask launch];
    [xmodmapTask waitUntilExit];
    return [xmodmapTask terminationStatus] == 0;
}

@end
