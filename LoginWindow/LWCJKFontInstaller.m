/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWCJKFontInstaller.h"
#import "LWCJKFont.h"
#include <sys/utsname.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>

/* The desktop's own fontconfig setup, which LoginWindow.sh and Gershwin.sh
   export; checking coverage against any other configuration could report a
   font the session never sees. */
static NSString * const kFontconfigFile = @"/System/Library/Preferences/fonts.conf";
static NSString * const kLicenseName = @"SarasaGothic-OFL.txt";

/* LoginWindow is started by init scripts whose PATH lacks /usr/local/bin on
   the BSDs, where curl and fc-list live. */
static NSString *findTool(NSString *name)
{
    NSArray *dirs = [NSArray arrayWithObjects:@"/usr/local/bin", @"/usr/bin",
        @"/bin", @"/usr/local/sbin", @"/usr/sbin", @"/sbin", nil];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static void fatal(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    fprintf(stderr, "FATAL: [LoginWindow] CJK font: %s\n", [msg UTF8String]);
    fflush(stderr);
}

static void logLine(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    fprintf(stderr, "[LoginWindow] CJK font: %s\n", [msg UTF8String]);
    fflush(stderr);
}

/* Runs a tool to completion; returns its stdout, or nil when it could not be
   started or exited non-zero. */
static NSString *runTool(NSString *name, NSArray *args)
{
    NSString *path = findTool(name);
    if (!path) {
        fatal(@"%@ not found", name);
        return nil;
    }
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSMutableDictionary *env = [[[[NSProcessInfo processInfo] environment]
        mutableCopy] autorelease];
    [env setObject:kFontconfigFile forKey:@"FONTCONFIG_FILE"];
    [task setLaunchPath:path];
    [task setArguments:args];
    [task setEnvironment:env];
    [task setStandardOutput:pipe];
    @try {
        [task launch];
    } @catch (NSException *e) {
        fatal(@"could not start %@: %@", path, [e reason]);
        return nil;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if ([task terminationStatus] != 0) {
        fatal(@"%@ %@ exited with status %d", path,
              [args componentsJoinedByString:@" "], [task terminationStatus]);
        return nil;
    }
    return [[[NSString alloc] initWithData:data
                                  encoding:NSUTF8StringEncoding] autorelease];
}

static NSString *sha256OfFile(NSString *path, NSString *osName)
{
    /* coreutils on Linux, sha256(1) from the base system on the BSDs. */
    NSString *out = [osName isEqualToString:@"Linux"]
        ? runTool(@"sha256sum", [NSArray arrayWithObject:path])
        : runTool(@"sha256", [NSArray arrayWithObjects:@"-q", path, nil]);
    NSArray *words = [[out stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsSeparatedByString:@" "];
    return [words count] ? [[words objectAtIndex:0] lowercaseString] : nil;
}

static BOOL installFile(NSString *from, NSString *to)
{
    if (chmod([from fileSystemRepresentation], 0644) != 0) {
        fatal(@"chmod %@: %s", from, strerror(errno));
        return NO;
    }
    /* rename(2) replaces atomically, so fontconfig never scans a half
       written font, and EXDEV fails hard instead of copying. */
    if (rename([from fileSystemRepresentation], [to fileSystemRepresentation]) != 0) {
        fatal(@"rename %@ -> %@: %s", from, to, strerror(errno));
        return NO;
    }
    return YES;
}

static int installAsset(NSDictionary *asset, NSString *osName,
                        NSString *staging, NSString *license)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *archive = [staging stringByAppendingPathComponent:
        [asset objectForKey:LWCJKFontArchiveKey]];
    NSString *url = [asset objectForKey:LWCJKFontURLKey];

    logLine(@"downloading %@", url);
    NSArray *curlArgs = [NSArray arrayWithObjects:@"--fail", @"--silent",
        @"--show-error", @"--location", @"--proto", @"=https",
        @"--proto-redir", @"=https", @"--output", archive, url, nil];
    if (!runTool(@"curl", curlArgs)) {
        fatal(@"download of %@ failed (offline?); CJK text will show as boxes", url);
        return 1;
    }

    NSString *want = [asset objectForKey:LWCJKFontSHA256Key];
    NSString *have = sha256OfFile(archive, osName);
    if (![want isEqualToString:have]) {
        fatal(@"sha256 mismatch for %@: expected %@, got %@; file deleted",
              archive, want, have ?: @"(none)");
        return 1;
    }

    NSString *unpacked = [staging stringByAppendingPathComponent:@"unpacked"];
    if (![fm createDirectoryAtPath:unpacked withIntermediateDirectories:NO
                        attributes:nil error:NULL]) {
        fatal(@"could not create %@", unpacked);
        return 1;
    }
    NSArray *members = [asset objectForKey:LWCJKFontMembersKey];
    NSMutableArray *tarArgs = [NSMutableArray arrayWithObjects:
        @"-x", @"-f", archive, @"-C", unpacked, nil];
    [tarArgs addObjectsFromArray:members];
    /* The archive is LZMA2 with a 192 MB dictionary; bsdtar needs about
       that much memory to unpack it. */
    if (!runTool(@"bsdtar", tarArgs)) {
        fatal(@"extracting %@ failed (bsdtar from libarchive needs about "
              @"192 MB of free memory for it)", archive);
        return 1;
    }

    if (![fm fileExistsAtPath:LWCJKFontInstallDirectory]
        && ![fm createDirectoryAtPath:LWCJKFontInstallDirectory
          withIntermediateDirectories:NO
                           attributes:[NSDictionary dictionaryWithObject:
                               [NSNumber numberWithShort:0755]
                                                                  forKey:NSFilePosixPermissions]
                                error:NULL]) {
        fatal(@"could not create %@", LWCJKFontInstallDirectory);
        return 1;
    }

    /* The OFL asks for the license to travel with the fonts. */
    NSString *stagedLicense = [staging stringByAppendingPathComponent:kLicenseName];
    if (![fm copyItemAtPath:license toPath:stagedLicense error:NULL]) {
        fatal(@"could not copy the license %@", license);
        return 1;
    }
    if (!installFile(stagedLicense, [LWCJKFontInstallDirectory
            stringByAppendingPathComponent:kLicenseName])) {
        return 1;
    }

    for (NSString *member in members) {
        if (!installFile([unpacked stringByAppendingPathComponent:member],
                         [LWCJKFontInstallDirectory
                             stringByAppendingPathComponent:member])) {
            return 1;
        }
    }

    if (!runTool(@"fc-cache", [NSArray arrayWithObject:LWCJKFontInstallDirectory])) {
        fatal(@"fc-cache failed after installing %@",
              [members componentsJoinedByString:@", "]);
        return 1;
    }
    logLine(@"installed %@ into %@", [members componentsJoinedByString:@", "],
            LWCJKFontInstallDirectory);
    return 0;
}

int LWInstallCJKFont(NSString *locale, NSString *licensePath)
{
    NSString *fcLang = LWCJKFontLanguageForLocale(locale);
    if (!fcLang) {
        logLine(@"locale %@ needs no CJK font", locale);
        return 0;
    }

    struct utsname un;
    if (uname(&un) != 0) {
        fatal(@"uname: %s", strerror(errno));
        return 1;
    }
    NSString *osName = [NSString stringWithUTF8String:un.sysname];

    NSString *listed = runTool(@"fc-list", [NSArray arrayWithObjects:
        [@":lang=" stringByAppendingString:fcLang], @"file", nil]);
    if (!listed) {
        return 1;
    }

    LWCJKFontDecision decision;
    NSDictionary *asset = LWCJKFontAssetForLocale(locale, listed, osName, &decision);
    switch (decision) {
    case LWCJKFontNotCJK:
        return 0;
    case LWCJKFontAlreadyCovered:
        logLine(@"fontconfig already has a font for %@", fcLang);
        return 0;
    case LWCJKFontUnsupportedOS:
        fatal(@"not supported on %@ (needs bsdtar from libarchive); "
              @"CJK text will show as boxes", osName);
        return 1;
    case LWCJKFontDownload:
        break;
    }

    /* Staging next to the fonts directory, so the final rename(2) stays on
       one filesystem, but outside it, so fontconfig never scans a partial
       download. */
    char tmpl[] = "/System/Library/.CJKFont-XXXXXX";
    if (!mkdtemp(tmpl)) {
        fatal(@"mkdtemp %s: %s", tmpl, strerror(errno));
        return 1;
    }
    NSString *staging = [NSString stringWithUTF8String:tmpl];
    int status = installAsset(asset, osName, staging, licensePath);
    [[NSFileManager defaultManager] removeItemAtPath:staging error:NULL];
    return status;
}
