/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* t_DisplaySystemDefaults - the system-wide scale file that LoginWindow
 * (source "recommended") and displayconfig write-system-scale (source
 * "user") share.  Headless; works in fresh directories under the temporary
 * directory only. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplaySystemDefaults.h"
#include <sys/stat.h>
#include <unistd.h>

static NSString *fresh(NSString *name)
{
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"t_DisplaySystemDefaults_%d_%@", getpid(), name]];
    [[NSFileManager defaultManager] removeFileAtPath:d handler:nil];
    return d;
}

static NSString *fileIn(NSString *d)
{
    return [d stringByAppendingPathComponent:DisplaySystemDefaultsFileName];
}

static void put(NSString *d, NSString *text)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:d attributes:nil];
    [text writeToFile:fileIn(d) atomically:NO];
}

static NSDictionary *readFile(NSString *d)
{
    return [NSDictionary dictionaryWithContentsOfFile:fileIn(d)];
}

static mode_t modeOf(NSString *path)
{
    struct stat st;
    return stat([path fileSystemRepresentation], &st) == 0 ? (st.st_mode & 07777) : 0;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray array];

    START_SET("file content")
        NSDictionary *d = DisplaySystemDefaultsBySettingScale(nil, 2.0, DisplayScaleSourceUser);
        PASS_EQUAL(d, ([NSDictionary dictionaryWithObjectsAndKeys:
                           [NSNumber numberWithDouble:2.0], @"GSScaleFactor",
                           @"user", @"GSScaleFactorSource", nil]),
                   "a new file holds GSScaleFactor and its source");
        d = DisplaySystemDefaultsBySettingScale(
            [NSDictionary dictionaryWithObjectsAndKeys:@"x", @"Other",
                [NSNumber numberWithDouble:1.0], @"GSScaleFactor",
                @"recommended", @"GSScaleFactorSource", nil], 1.5, DisplayScaleSourceUser);
        PASS([[d objectForKey:@"GSScaleFactor"] doubleValue] == 1.5
             && [[d objectForKey:@"Other"] isEqual:@"x"]
             && [[d objectForKey:@"GSScaleFactorSource"] isEqual:@"user"],
             "other keys survive, and LoginWindow's recommendation becomes the user's choice");
        PASS([DisplaySystemDefaultsPath() hasSuffix:@"/GlobalDefaults/Display.plist"],
             "the system file is GlobalDefaults/Display.plist");
    END_SET("file content")

    START_SET("recommended (LoginWindow)")
        NSString *d = fresh(@"absent");
        [dirs addObject:d];
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleAbsent,
             "missing directory is absent");
        PASS(DisplayWriteRecommendedScale(fileIn(d), 2.0, NULL), "write creates the directory");
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleRecommended,
             "written file is recommended");
        PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
                   [NSNumber numberWithDouble:2.0], "scale stored");
        PASS_EQUAL([readFile(d) objectForKey:DisplayScaleSourceKey],
                   DisplayScaleSourceRecommended, "source stored");
        PASS(modeOf(d) == 0755, "directory is 0755");
        PASS(modeOf(fileIn(d)) == 0644, "file is 0644");
        PASS([[fm directoryContentsAtPath:d] count] == 1,
             "no temporary file is left behind");
        PASS(DisplayWriteRecommendedScale(fileIn(d), 1.25, NULL), "recommended file is refreshed");
        PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
                   [NSNumber numberWithDouble:1.25], "new scale replaced old");

        d = fresh(@"user");
        [dirs addObject:d];
        put(d, @"{ GSScaleFactor = 1.5; GSScaleFactorSource = user; }");
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleConfigured,
             "source user is configured");
        PASS(DisplayWriteRecommendedScale(fileIn(d), 2.0, NULL), "user file: no error");
        PASS([[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 1.5,
             "user file is untouched");

        d = fresh(@"nosource");
        [dirs addObject:d];
        put(d, @"{ GSScaleFactor = 1.75; }");
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleConfigured,
             "scale without source is configured");
        DisplayWriteRecommendedScale(fileIn(d), 2.0, NULL);
        PASS([[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 1.75,
             "administrator file untouched");

        d = fresh(@"corrupt");
        [dirs addObject:d];
        put(d, @"this is { not a plist");
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleAbsent,
             "unparsable file is absent");
        PASS(DisplayWriteRecommendedScale(fileIn(d), 2.0, NULL), "corrupt file is replaced");
        PASS_EQUAL([readFile(d) objectForKey:@"GSScaleFactor"],
                   [NSNumber numberWithDouble:2.0], "replacement is valid");

        d = fresh(@"other");
        [dirs addObject:d];
        put(d, @"{ SomethingElse = 1; }");
        PASS(DisplaySystemScaleStateAtPath(fileIn(d)) == DisplaySystemScaleAbsent,
             "file without a scale is absent");
        PASS(DisplayWriteRecommendedScale(fileIn(d), 1.5, NULL)
             && [[readFile(d) objectForKey:@"SomethingElse"] intValue] == 1,
             "a recommendation keeps the keys others wrote");
    END_SET("recommended (LoginWindow)")

    START_SET("user (displayconfig)")
        NSString *d = fresh(@"userwrite");
        [dirs addObject:d];
        [fm createDirectoryAtPath:d attributes:nil];
        NSString *path = fileIn(d);
        mode_t old = umask(0);
        NSString *problem = nil;
        BOOL ok = DisplayWriteSystemScale(path, 1.25, DisplayScaleSourceUser, &problem);
        umask(old);
        PASS(ok && modeOf(path) == 0644, "the file is written with mode 0644 whatever the umask");
        PASS([[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 1.25
             && DisplaySystemScaleStateAtPath(path) == DisplaySystemScaleConfigured,
             "it holds the scale as a real, as the user's choice");
        chmod([path fileSystemRepresentation], 0666);
        ok = DisplayWriteSystemScale(path, 2.0, DisplayScaleSourceUser, &problem);
        PASS(ok && modeOf(path) == 0644
             && [[readFile(d) objectForKey:@"GSScaleFactor"] doubleValue] == 2.0,
             "rewriting a group-writable file leaves it at 0644 with the new scale");
        problem = nil;
        // A plain file as the parent directory, because root (as in CI) may
        // create any missing directory.
        NSString *notADir = [d stringByAppendingPathComponent:@"not-a-directory"];
        [fm createFileAtPath:notADir contents:[NSData data] attributes:nil];
        ok = DisplayWriteSystemScale([notADir stringByAppendingPathComponent:@"Display.plist"], 2.0,
                                     DisplayScaleSourceUser, &problem);
        PASS(!ok && problem != nil, "a file that cannot be written fails with a reason");
    END_SET("user (displayconfig)")

    for (NSString *d in dirs) {
        [fm removeFileAtPath:d handler:nil];
    }
    [arp release];
    return 0;
}
