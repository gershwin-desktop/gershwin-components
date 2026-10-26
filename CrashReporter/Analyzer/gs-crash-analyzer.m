/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSCrashAnalyzer.h"

static void usage(void)
{
    fprintf(stderr,
        "usage: gs-crash-analyzer <crashDirectory> [--executable <path>] "
        "[--core <path>] [--timeout <seconds>]\n");
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc < 2)
        {
            usage();
            return 2;
        }

        NSString *dir = nil;
        NSString *executable = nil;
        NSString *core = nil;
        NSTimeInterval timeout = 60.0;

        for (int i = 1; i < argc; i++)
        {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--executable"] && i + 1 < argc)
                executable = @(argv[++i]);
            else if ([arg isEqualToString:@"--core"] && i + 1 < argc)
                core = @(argv[++i]);
            else if ([arg isEqualToString:@"--timeout"] && i + 1 < argc)
                timeout = [@(argv[++i]) doubleValue];
            else if ([arg hasPrefix:@"-"])
            {
                fprintf(stderr, "unknown option: %s\n", argv[i]);
                usage();
                return 2;
            }
            else if (dir == nil)
                dir = arg;
        }

        if (dir == nil)
        {
            usage();
            return 2;
        }

        GSCrashAnalyzer *analyzer = [[GSCrashAnalyzer alloc] init];
        if (executable) [analyzer setExecutableHint:executable];
        if (core) [analyzer setCoreHint:core];
        [analyzer setTimeoutSeconds:timeout];

        NSError *error = nil;
        BOOL ok = [analyzer analyzeCrashDirectory:dir error:&error];
        if (!ok)
        {
            fprintf(stderr, "gs-crash-analyzer: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }
        printf("analysis complete: %s/report.json\n",
               [dir fileSystemRepresentation]);
        return 0;
    }
}
