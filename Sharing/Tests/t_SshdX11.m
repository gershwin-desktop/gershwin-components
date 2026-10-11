/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* The X11Forwarding editing of the Sharing helper.  sshd uses the first
 * occurrence of a directive and a directive below a Match line only applies
 * to that block, so a naive "append a line" or "replace every line" would
 * either be ignored or change the wrong thing.  Everything here runs on
 * strings and scratch directories; /etc/ssh is never read. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include <sys/stat.h>
#include <unistd.h>
#include "sshd-x11.h"

static char *NoInclude(const char *pattern, int idx, void *ctx)
{
    (void)pattern; (void)idx; (void)ctx;
    return NULL;
}

static int Reject(const char *path, void *ctx)
{
    (void)path; (void)ctx;
    return 1;
}

static NSString *Edit(NSString *in, BOOL enable)
{
    char *out = NULL;
    char err[256] = "";
    if (sshd_x11_edit([in UTF8String], NoInclude, NULL, enable, &out, err, sizeof(err)) != 0) {
        return [NSString stringWithFormat:@"ERROR: %s", err];
    }
    NSString *s = [NSString stringWithUTF8String:out];
    free(out);
    return s;
}

static int Effective(NSString *in)
{
    int v = -1;
    char err[256];
    if (sshd_x11_effective([in UTF8String], NoInclude, NULL, &v, err, sizeof(err)) != 0) return -2;
    return v;
}

static NSString *Slurp(NSString *path)
{
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    /* Reading */
    PASS_EQUAL([NSNumber numberWithInt:Effective(@"Port 22\n")], [NSNumber numberWithInt:0],
               "no directive means no");
    PASS(Effective(@"X11Forwarding yes\n") == 1, "yes is read");
    PASS(Effective(@"  x11forwarding=No\n") == 0, "keyword case, equals sign and indent");
    PASS(Effective(@"#X11Forwarding yes\n") == 0, "a comment is not a directive");
    PASS(Effective(@"X11Forwarding no\nX11Forwarding yes\n") == 0, "first occurrence wins");
    PASS(Effective(@"Match User bob\n  X11Forwarding yes\n") == 0, "Match block does not count");
    PASS(Effective(@"X11Forwarding maybe\n") == -2, "an unknown value fails");
    PASS(Effective(@"X11Forwarding yes extra\n") == -2, "garbage after the value fails");
    PASS(Effective(@"X11Forwarding yes # why\n") == 1, "trailing comment is fine");

    /* Replacing an existing line changes only the value */
    PASS_EQUAL(Edit(@"Port 22\nX11Forwarding no\nUsePAM yes\n", YES),
               @"Port 22\nX11Forwarding yes\nUsePAM yes\n", "no -> yes in place");
    PASS_EQUAL(Edit(@"\tx11forwarding = yes # keep\n", NO),
               @"\tx11forwarding = no # keep\n", "spacing, case and comment kept");
    PASS_EQUAL(Edit(@"X11Forwarding yes\n", YES), @"X11Forwarding yes\n", "already set: unchanged");
    PASS_EQUAL(Edit(@"X11Forwarding no", YES), @"X11Forwarding yes", "no trailing newline kept as is");
    PASS_EQUAL(Edit(@"X11Forwarding no\nX11Forwarding no\n", YES),
               @"X11Forwarding yes\nX11Forwarding no\n", "only the effective (first) line");
    PASS_EQUAL(Edit(@"#X11Forwarding no\nMatch User a\n X11Forwarding no\n", YES),
               @"#X11Forwarding no\n"
               @"# Set by the Sharing preference pane\nX11Forwarding yes\n"
               @"Match User a\n X11Forwarding no\n",
               "commented and Match lines are left alone, new line goes before Match");

    /* Adding */
    PASS_EQUAL(Edit(@"Port 22\n", YES),
               @"Port 22\n# Set by the Sharing preference pane\nX11Forwarding yes\n", "appended");
    PASS_EQUAL(Edit(@"Port 22", NO),
               @"Port 22\n# Set by the Sharing preference pane\nX11Forwarding no\n",
               "newline added before appending");
    PASS_EQUAL(Edit(@"", YES),
               @"# Set by the Sharing preference pane\nX11Forwarding yes\n", "empty file");
    PASS_EQUAL(Edit(@"Port 22\nMatch Address 10.*\n  PasswordAuthentication yes\n", YES),
               @"Port 22\n# Set by the Sharing preference pane\nX11Forwarding yes\n"
               @"Match Address 10.*\n  PasswordAuthentication yes\n", "inserted before first Match");

    /* Malformed */
    PASS([Edit(@"X11Forwarding\n", YES) hasPrefix:@"ERROR"], "missing value fails");
    PASS([Edit(@"X11Forwarding sometimes\n", YES) hasPrefix:@"ERROR"], "bad value fails");

    /* Include handling on a scratch tree */
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"sshdx11-%d", (int)getpid()]];
    NSString *dropins = [dir stringByAppendingPathComponent:@"sshd_config.d"];
    [fm createDirectoryAtPath:dropins withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *cfg = [dir stringByAppendingPathComponent:@"sshd_config"];
    NSString *drop = [dropins stringByAppendingPathComponent:@"10-x.conf"];
    NSString *base = @"Include /etc/ssh/none.d/*.conf sshd_config.d/*.conf\nPort 22\nX11Forwarding no\n";
    char err[256] = "";
    int en = -1, changed = -1;

    [@"Port 22\n" writeToFile:drop atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [base writeToFile:cfg atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    chmod([cfg fileSystemRepresentation], 0640);
    PASS(sshd_x11_read_file([cfg fileSystemRepresentation], &en, err, sizeof(err)) == 0 && en == 0,
         "include without the directive: main file decides");
    PASS(sshd_x11_rewrite_file([cfg fileSystemRepresentation], 1, NULL, NULL, &changed, err, sizeof(err)) == 0
         && changed == 1, "rewrite succeeds");
    PASS_EQUAL(Slurp(cfg),
               @"Include /etc/ssh/none.d/*.conf sshd_config.d/*.conf\nPort 22\nX11Forwarding yes\n",
               "only the one value changed in the file");
    struct stat st;
    stat([cfg fileSystemRepresentation], &st);
    PASS((st.st_mode & 07777) == 0640, "mode kept");
    PASS(![fm fileExistsAtPath:[cfg stringByAppendingString:@".sharing-new"]], "no temp file left");
    PASS(sshd_x11_rewrite_file([cfg fileSystemRepresentation], 1, NULL, NULL, &changed, err, sizeof(err)) == 0
         && changed == 0, "second identical request changes nothing");

    [@"X11Forwarding no\n" writeToFile:drop atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    PASS(sshd_x11_read_file([cfg fileSystemRepresentation], &en, err, sizeof(err)) == 0 && en == 0,
         "an include that comes first decides the effective value");
    NSString *before = Slurp(cfg);
    PASS(sshd_x11_rewrite_file([cfg fileSystemRepresentation], 1, NULL, NULL, &changed, err, sizeof(err)) != 0
         && strlen(err) > 0, "refuses to edit when an include decides");
    PASS_EQUAL(Slurp(cfg), before, "refused edit leaves the file alone");

    /* A validator that rejects keeps the old file */
    [@"Port 22\n" writeToFile:drop atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    before = Slurp(cfg);
    PASS(sshd_x11_rewrite_file([cfg fileSystemRepresentation], 0, Reject, NULL,
                               &changed, err, sizeof(err)) != 0, "rejected by sshd -t");
    PASS_EQUAL(Slurp(cfg), before, "old file kept");
    PASS(![fm fileExistsAtPath:[cfg stringByAppendingString:@".sharing-new"]], "temp file removed");

    [fm removeItemAtPath:dir error:NULL];
    [pool release];
    return 0;
}
