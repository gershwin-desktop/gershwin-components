/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* displayconfig - the per-user display configuration on the command line.
 *
 *   displayconfig apply                 bring the server to the saved layout
 *                                       for the connected monitors, or to a
 *                                       sane default when none is saved
 *   displayconfig save                  save what the server runs now
 *   displayconfig print [--json]        show the key and both layouts
 *   displayconfig write-system-scale F  set GSScaleFactor for LoginWindow
 *                                       and new users (asks for root)
 *
 * The WindowManager runs "apply" at login and after every RandR change, so
 * "apply" must not change anything when the server already runs the
 * wanted layout: an unneeded change would be another RandR event. */

#import <Foundation/Foundation.h>
#import <PackageManager/GWSudoHelper.h>

#import "DisplayLayout.h"
#import "DisplayArrangement.h"
#import "DisplayConfiguration.h"
#import "X11DisplayManager.h"

#import <stdio.h>
#import <unistd.h>

enum {
    ExitOK = 0,
    ExitUsage = 1,
    ExitNoDisplay = 2,
    ExitSavedLayoutUnusable = 3,
    ExitServerRefused = 4,
    ExitNotSaved = 5
};

static void complain(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *text = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    fprintf(stderr, "displayconfig: %s\n", [text UTF8String]);
}

static void say(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *text = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    printf("%s\n", [text UTF8String]);
    fflush(stdout);
}

static double effectiveScaleFactor(void)
{
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"GSScaleFactor"];
    return stored ? [stored doubleValue] : 1.0;
}

static DisplayLayout *readServer(X11DisplayManager *x11)
{
    if (![x11 isAvailable]) {
        complain(@"cannot open the X display \"%s\" or it has no RandR",
                 getenv("DISPLAY") ?: "");
        return nil;
    }
    DisplayLayout *current = [x11 currentLayoutProbingOutputs:NO];
    if (current == nil || [[current outputs] count] == 0) {
        complain(@"the X server reports no connected display");
        return nil;
    }
    [current setScaleFactor:effectiveScaleFactor()];
    return current;
}

static int apply(void)
{
    X11DisplayManager *x11 = [[[X11DisplayManager alloc] init] autorelease];
    DisplayLayout *current = readServer(x11);
    if (current == nil) return ExitNoDisplay;

    NSString *key = [current configurationKey];
    DisplayLayout *saved = [[DisplayLayoutStore userStore] layoutForKey:key];
    NSString *problem = nil;
    DisplayLayout *wanted = saved ? DisplayResolveSavedLayout(saved, current, &problem)
                                  : DisplayDefaultLayout(current);
    int status = ExitOK;
    if (wanted == nil) {
        complain(@"the saved layout for %@ cannot be applied: %@", key, problem);
        status = ExitSavedLayoutUnusable;
    } else if (DisplayLayoutsDiffer(wanted, current) || [x11 hasStrayStateForLayout:wanted]) {
        NSError *error = nil;
        if (![x11 applyLayout:wanted touchedServer:NULL error:&error]) {
            complain(@"applying the %@ layout for %@ failed: %@",
                     saved ? @"saved" : @"default", key, [error localizedDescription]);
            return ExitServerRefused;
        }
        say(@"applied the %@ layout for %@", saved ? @"saved" : @"default", key);
    } else {
        say(@"unchanged: the server already runs the %@ layout for %@",
            saved ? @"saved" : @"default", key);
    }

    /* NSScreen's first screen, and with it the menu bar, follows the RandR
     * primary; without one every client guesses on its own. */
    NSString *primary = [[(wanted ? wanted : current) primaryOutput] name];
    if (primary && ![primary isEqualToString:[x11 primaryOutputName]]) {
        NSError *error = nil;
        if (![x11 setPrimaryOutputNamed:primary error:&error]) {
            complain(@"%@", [error localizedDescription]);
            return ExitServerRefused;
        }
        say(@"made %@ the primary display", primary);
    }
    return status;
}

static int save(void)
{
    X11DisplayManager *x11 = [[[X11DisplayManager alloc] init] autorelease];
    DisplayLayout *current = readServer(x11);
    if (current == nil) return ExitNoDisplay;
    if (![[DisplayLayoutStore userStore] saveLayout:current]) {
        complain(@"the layout could not be written to the defaults domain %@",
                 DisplayLayoutsDomain);
        return ExitNotSaved;
    }
    say(@"saved the layout for %@", [current configurationKey]);
    return ExitOK;
}

static int print(BOOL json)
{
    X11DisplayManager *x11 = [[[X11DisplayManager alloc] init] autorelease];
    DisplayLayout *current = readServer(x11);
    if (current == nil) return ExitNoDisplay;
    NSString *key = [current configurationKey];
    DisplayLayout *saved = [[DisplayLayoutStore userStore] layoutForKey:key];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:key forKey:@"key"];
    [d setObject:[current propertyList] forKey:@"current"];
    if (saved) [d setObject:[saved propertyList] forKey:@"saved"];
    NSString *primary = [x11 primaryOutputName];
    if (primary) [d setObject:primary forKey:@"randrPrimary"];

    if (json) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:d
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
        if (data == nil) {
            complain(@"cannot encode JSON: %@", [error localizedDescription]);
            return ExitUsage;
        }
        fwrite([data bytes], 1, [data length], stdout);
        printf("\n");
        return ExitOK;
    }
    say(@"key: %@", key);
    say(@"RandR primary: %@", primary ? primary : @"(none)");
    for (DisplayOutput *o in [current outputs]) say(@"current: %@", o);
    if (saved) {
        for (DisplayOutput *o in [saved outputs]) say(@"saved:   %@", o);
        say(@"saved scale: %g", [saved scaleFactor]);
    } else {
        say(@"saved:   (nothing saved for these monitors)");
    }
    return ExitOK;
}

/* As the user: run this tool again through sudo, so SudoAskPass asks for
 * the password; as root: write the file. */
static int writeSystemScale(NSString *argument)
{
    double factor = [argument doubleValue];
    if (factor <= 0 || DisplayClampScaleFactor(factor) != factor) {
        complain(@"%@ is not one of the offered scale factors", argument);
        return ExitUsage;
    }
    if (geteuid() != 0) {
        NSArray *args = nil;
        NSString *launch = GWSudoCommand([[NSBundle mainBundle] executablePath],
                                         [NSArray arrayWithObjects:@"write-system-scale",
                                                                   argument, nil],
                                         &args);
        NSTask *task = [[[NSTask alloc] init] autorelease];
        [task setLaunchPath:launch];
        [task setArguments:args];
        @try {
            [task launch];
        } @catch (NSException *e) {
            complain(@"cannot run %@: %@", launch, [e reason]);
            return ExitNotSaved;
        }
        [task waitUntilExit];
        if ([task terminationStatus] != 0) {
            complain(@"writing the system-wide scale as root failed (status %d)",
                     [task terminationStatus]);
            return ExitNotSaved;
        }
        return ExitOK;
    }
    NSString *path = DisplaySystemDefaultsPath();
    NSString *problem = nil;
    if (!DisplayWriteSystemScale(path, factor, &problem)) {
        complain(@"%@", problem);
        return ExitNotSaved;
    }
    say(@"wrote GSScaleFactor %g to %@", factor, path);
    return ExitOK;
}

static int usage(void)
{
    fprintf(stderr,
            "usage: displayconfig apply\n"
            "       displayconfig save\n"
            "       displayconfig print [--json]\n"
            "       displayconfig write-system-scale FACTOR\n");
    return ExitUsage;
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    NSString *command = [args count] > 1 ? [args objectAtIndex:1] : nil;
    int status;
    if ([command isEqualToString:@"apply"] && [args count] == 2) {
        status = apply();
    } else if ([command isEqualToString:@"save"] && [args count] == 2) {
        status = save();
    } else if ([command isEqualToString:@"print"] && [args count] == 2) {
        status = print(NO);
    } else if ([command isEqualToString:@"print"] && [args count] == 3
               && [[args objectAtIndex:2] isEqualToString:@"--json"]) {
        status = print(YES);
    } else if ([command isEqualToString:@"write-system-scale"] && [args count] == 3) {
        status = writeSystemScale([args objectAtIndex:2]);
    } else {
        status = usage();
    }
    [pool release];
    return status;
}
