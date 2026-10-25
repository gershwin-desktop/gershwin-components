/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_DisplayConfiguration - the per-user display configuration: the
 * configuration key, the layout chosen for monitors seen for the first
 * time, a saved layout laid onto the monitors connected now, the "differs"
 * check that keeps apply idempotent, the per-user store and the system-wide
 * scale file.  Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "DisplayLayout.h"
#import "DisplayConfiguration.h"

#import <sys/stat.h>
#import <unistd.h>

static DisplayMode *M(unsigned long ident, int w, int h, double r, BOOL pref)
{
    return [DisplayMode modeWithID:ident width:w height:h refresh:r
                        interlaced:NO preferred:pref];
}

static NSArray *panelModes(void)
{
    return [NSArray arrayWithObjects:M(1, 2560, 1600, 60, YES),
            M(2, 1920, 1200, 60, NO), M(3, 1280, 800, 60, NO), nil];
}

static NSArray *monitorModes(void)
{
    return [NSArray arrayWithObjects:M(11, 2560, 1440, 60, NO),
            M(12, 1920, 1080, 60, YES), M(13, 1920, 1080, 75, NO),
            M(14, 1280, 1024, 60, NO), nil];
}

static DisplayOutput *O(NSString *name, NSString *edid, NSArray *modes, BOOL enabled,
                        int w, int h, int x, int y, BOOL primary)
{
    DisplayOutput *o = [[[DisplayOutput alloc] init] autorelease];
    [o setName:name];
    [o setEdidIdentity:edid];
    [o setConnected:YES];
    [o setEnabled:enabled];
    [o setModes:modes];
    [o setModeWidth:w];
    [o setModeHeight:h];
    [o setModeRefresh:60];
    [o setX:x];
    [o setY:y];
    [o setPrimary:primary];
    return o;
}

static DisplayLayout *L(DisplayOutput *first, ...)
{
    NSMutableArray *outs = [NSMutableArray array];
    va_list ap;
    va_start(ap, first);
    for (DisplayOutput *o = first; o != nil; o = va_arg(ap, DisplayOutput *)) {
        [outs addObject:o];
    }
    va_end(ap);
    return [DisplayLayout layoutWithOutputs:outs];
}

static NSString *geometry(DisplayLayout *l, NSString *name)
{
    DisplayOutput *o = [l outputNamed:name];
    if (o == nil) return @"missing";
    if (![o enabled]) return @"off";
    return [NSString stringWithFormat:@"%dx%d+%d+%d%@", [o modeWidth], [o modeHeight],
            [o x], [o y], [o primary] ? @" primary" : @""];
}

static NSString * const kPanel = @"BOE-0A1B-00000000";
static NSString * const kDell = @"DEL-A0B1-12345678";

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    START_SET("configuration key")
        DisplayLayout *a = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES),
                             O(@"HDMI-1", kDell, monitorModes(), NO, 1920, 1080, 0, 0, NO), nil);
        DisplayLayout *b = L(O(@"DP-2", kDell, monitorModes(), YES, 1920, 1080, 0, 0, YES),
                             O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 1920, 0, NO), nil);
        PASS_EQUAL([a configurationKey], [b configurationKey],
                   "the same monitors on other connectors, in another order, give the same key");
        DisplayLayout *c = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES), nil);
        PASS(![[a configurationKey] isEqual:[c configurationKey]],
             "unplugging a monitor changes the key");
        DisplayLayout *d = L(O(@"VGA-1", nil, monitorModes(), YES, 1920, 1080, 0, 0, YES), nil);
        PASS_EQUAL([d configurationKey], @"connector:VGA-1",
                   "a monitor without EDID is known by its connector");
    END_SET("configuration key")

    START_SET("default layout for monitors seen the first time")
        DisplayLayout *cur = L(O(@"eDP-1", kPanel, panelModes(), YES, 1920, 1200, 0, 0, YES),
                               O(@"HDMI-1", kDell, monitorModes(), NO, 1920, 1080, 0, 0, NO), nil);
        DisplayLayout *def = DisplayDefaultLayout(cur);
        PASS_EQUAL(geometry(def, @"eDP-1"), @"1920x1200+0+0 primary",
                   "a lit output keeps its mode and place (no mode switch at login)");
        PASS_EQUAL(geometry(def, @"HDMI-1"), @"1920x1080+1920+0",
                   "a dark output is lit at its preferred mode to the right");

        DisplayLayout *clone = L(O(@"eDP-1", kPanel, panelModes(), YES, 1920, 1200, 0, 0, NO),
                                 O(@"HDMI-1", kDell, monitorModes(), YES, 1280, 1024, 0, 0, NO), nil);
        def = DisplayDefaultLayout(clone);
        PASS_EQUAL(geometry(def, @"eDP-1"), @"2560x1600+0+0 primary",
                   "outputs overlapping at 0,0: the first is primary at its preferred mode");
        PASS_EQUAL(geometry(def, @"HDMI-1"), @"1920x1080+2560+0",
                   "outputs overlapping at 0,0: the other goes right of it at its preferred mode");

        DisplayLayout *leftover = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 1024, YES), nil);
        def = DisplayDefaultLayout(leftover);
        PASS_EQUAL(geometry(def, @"eDP-1"), @"2560x1600+0+0 primary",
                   "the output left after its neighbor above was unplugged moves to 0,0");

        DisplayLayout *noPrimary = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, NO), nil);
        def = DisplayDefaultLayout(noPrimary);
        PASS([[def primaryOutput] name] != nil, "a primary is always set");

        DisplayLayout *mirror = L(O(@"eDP-1", kPanel, panelModes(), YES, 1920, 1200, 0, 0, YES),
                                  O(@"HDMI-1", kDell, monitorModes(), YES, 1920, 1200, 0, 0, NO), nil);
        [[mirror outputNamed:@"HDMI-1"] setModes:[NSArray arrayWithObject:M(20, 1920, 1200, 60, YES)]];
        def = DisplayDefaultLayout(mirror);
        PASS([def isMirrored], "an exact mirror is a deliberate setup and stays");
        PASS(def != nil && !DisplayLayoutsDiffer(DisplayDefaultLayout(def), def),
             "the default of a default changes nothing");
    END_SET("default layout for monitors seen the first time")

    START_SET("saved layout laid onto the monitors connected now")
        DisplayLayout *saved = L(O(@"HDMI-1", kDell, monitorModes(), YES, 2560, 1440, 0, 0, YES),
                                 O(@"eDP-1", kPanel, panelModes(), YES, 1920, 1200, 0, 1440, NO), nil);
        saved = [DisplayLayout layoutWithPropertyList:[saved propertyList]];
        DisplayLayout *now = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES),
                               O(@"DP-3", kDell, monitorModes(), NO, 1920, 1080, 0, 0, NO), nil);
        NSString *problem = nil;
        DisplayLayout *r = DisplayResolveSavedLayout(saved, now, &problem);
        PASS(r != nil, "a saved layout for the same monitors resolves");
        PASS_EQUAL(geometry(r, @"DP-3"), @"2560x1440+0+0 primary",
                   "the monitor is found by EDID on its new connector and is primary again");
        PASS_EQUAL(geometry(r, @"eDP-1"), @"1920x1200+0+1440",
                   "the panel gets its saved mode and place below");
        PASS([[[r outputNamed:@"DP-3"] modes] count] == 4,
             "the resolved layout keeps the server's mode list");
        PASS(DisplayLayoutsDiffer(r, now), "and it differs from what runs now");

        DisplayLayout *other = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES), nil);
        problem = nil;
        PASS(DisplayResolveSavedLayout(saved, other, &problem) == nil && problem != nil,
             "a layout for other monitors does not resolve, with a reason");

        DisplayLayout *lost = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES),
                                O(@"DP-3", kDell, [NSArray arrayWithObject:M(12, 1920, 1080, 60, YES)],
                                  NO, 1920, 1080, 0, 0, NO), nil);
        problem = nil;
        PASS(DisplayResolveSavedLayout(saved, lost, &problem) == nil && problem != nil
             && [problem rangeOfString:@"2560x1440"].location != NSNotFound,
             "a saved mode the monitor no longer offers fails loudly instead of guessing");

        DisplayLayout *twins = L(O(@"DP-1", kDell, monitorModes(), YES, 1920, 1080, 0, 0, YES),
                                 O(@"DP-2", kDell, monitorModes(), YES, 1280, 1024, 1920, 0, NO), nil);
        DisplayLayout *twinsSaved = [DisplayLayout layoutWithPropertyList:[twins propertyList]];
        DisplayLayout *twinsNow = L(O(@"DP-1", kDell, monitorModes(), YES, 1920, 1080, 0, 0, YES),
                                    O(@"DP-2", kDell, monitorModes(), YES, 1920, 1080, 1920, 0, NO), nil);
        r = DisplayResolveSavedLayout(twinsSaved, twinsNow, &problem);
        PASS_EQUAL(geometry(r, @"DP-2"), @"1280x1024+1920+0",
                   "two monitors with the same EDID keep their own connectors");
    END_SET("saved layout laid onto the monitors connected now")

    START_SET("differs")
        DisplayLayout *a = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES),
                             O(@"HDMI-1", kDell, monitorModes(), YES, 1920, 1080, 2560, 0, NO), nil);
        DisplayLayout *b = [[a copy] autorelease];
        PASS(!DisplayLayoutsDiffer(a, b), "the same layout does not differ");
        [[b outputNamed:@"HDMI-1"] setModeRefresh:60.2];
        PASS(!DisplayLayoutsDiffer(a, b), "a refresh within 0.5 Hz is the same mode");
        [[b outputNamed:@"HDMI-1"] setModeRefresh:75];
        PASS(DisplayLayoutsDiffer(a, b), "another refresh differs");
        b = [[a copy] autorelease];
        [[b outputNamed:@"HDMI-1"] setX:2561];
        PASS(DisplayLayoutsDiffer(a, b), "another position differs");
        b = [[a copy] autorelease];
        [[b outputNamed:@"HDMI-1"] setPrimary:YES];
        [[b outputNamed:@"eDP-1"] setPrimary:NO];
        PASS(DisplayLayoutsDiffer(a, b), "another primary differs");
        b = [[a copy] autorelease];
        [[b outputNamed:@"HDMI-1"] setEnabled:NO];
        PASS(DisplayLayoutsDiffer(a, b), "a dark output differs");
        b = [[a copy] autorelease];
        [[b outputNamed:@"HDMI-1"] setTransformScaleX:1.5];
        PASS(DisplayLayoutsDiffer(a, b), "a transform differs");
        b = [[a copy] autorelease];
        [[b outputNamed:@"HDMI-1"] setModeHeight:1080];
        [[b outputNamed:@"HDMI-1"] setModeWidth:1920];
        [[b outputNamed:@"HDMI-1"] setModes:[NSArray array]];
        [b setScaleFactor:2.0];
        PASS(!DisplayLayoutsDiffer(a, b),
             "the mode list and the interface scale are not server state");
    END_SET("differs")

    START_SET("per-user store")
        NSString *domain = @"io.github.gershwin-desktop.DisplayLayouts.t_DisplayConfiguration";
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
        DisplayLayoutStore *store = [[[DisplayLayoutStore alloc] initWithDomainName:domain] autorelease];
        DisplayLayout *l = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES),
                             O(@"HDMI-1", kDell, monitorModes(), YES, 1920, 1080, 2560, 0, NO), nil);
        [l setScaleFactor:1.5];
        PASS([store layoutForKey:[l configurationKey]] == nil, "nothing is saved at first");
        PASS([store saveLayout:l], "a layout is saved");
        DisplayLayoutStore *again = [[[DisplayLayoutStore alloc] initWithDomainName:domain] autorelease];
        DisplayLayout *back = [again layoutForKey:[l configurationKey]];
        PASS(back != nil && !DisplayLayoutsDiffer(back, l) && [back scaleFactor] == 1.5,
             "it comes back under its key with modes, places, primary and scale");
        NSDictionary *raw = [[NSUserDefaults standardUserDefaults] persistentDomainForName:domain];
        PASS([[raw objectForKey:[l configurationKey]] isKindOfClass:[NSDictionary class]],
             "the domain maps the configuration key to the layout's property list");
        DisplayLayout *single = L(O(@"eDP-1", kPanel, panelModes(), YES, 2560, 1600, 0, 0, YES), nil);
        [store saveLayout:single];
        PASS([[again allLayouts] count] == 2, "each set of monitors has its own layout");
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];
        PASS_EQUAL(DisplayLayoutsDomain, @"io.github.gershwin-desktop.DisplayLayouts",
                   "the user's layouts live in the Gershwin reverse-DNS domain");
    END_SET("per-user store")

    START_SET("system-wide scale")
        NSDictionary *d = DisplaySystemDefaultsBySettingScale(nil, 2.0);
        PASS_EQUAL(d, ([NSDictionary dictionaryWithObjectsAndKeys:
                           [NSNumber numberWithDouble:2.0], @"GSScaleFactor",
                           @"user", @"GSScaleFactorSource", nil]),
                   "a new file holds GSScaleFactor, marked as the user's choice");
        d = DisplaySystemDefaultsBySettingScale(
            [NSDictionary dictionaryWithObjectsAndKeys:@"x", @"Other",
                [NSNumber numberWithDouble:1.0], @"GSScaleFactor",
                @"recommended", @"GSScaleFactorSource", nil], 1.5);
        PASS([[d objectForKey:@"GSScaleFactor"] doubleValue] == 1.5
             && [[d objectForKey:@"Other"] isEqual:@"x"]
             && [[d objectForKey:@"GSScaleFactorSource"] isEqual:@"user"],
             "other keys survive a scale change, and LoginWindow's recommendation becomes the user's choice");

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"t_DisplayConfiguration.%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"Display.plist"];
        mode_t old = umask(0);
        NSString *problem = nil;
        BOOL ok = DisplayWriteSystemScale(path, 1.25, &problem);
        umask(old);
        struct stat st;
        PASS(ok && stat([path fileSystemRepresentation], &st) == 0
             && (st.st_mode & 07777) == 0644,
             "the file is written with mode 0644 whatever the umask");
        NSDictionary *back = [NSDictionary dictionaryWithContentsOfFile:path];
        PASS([[back objectForKey:@"GSScaleFactor"] doubleValue] == 1.25,
             "it holds the scale as a real");
        chmod([path fileSystemRepresentation], 0666);
        ok = DisplayWriteSystemScale(path, 2.0, &problem);
        PASS(ok && stat([path fileSystemRepresentation], &st) == 0
             && (st.st_mode & 07777) == 0644
             && [[[NSDictionary dictionaryWithContentsOfFile:path]
                    objectForKey:@"GSScaleFactor"] doubleValue] == 2.0,
             "rewriting a group-writable file leaves it at 0644 with the new scale");
        problem = nil;
        ok = DisplayWriteSystemScale(@"/nonexistent-dir/Display.plist", 2.0, &problem);
        PASS(!ok && problem != nil, "a file that cannot be written fails with a reason");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];

        PASS([DisplaySystemDefaultsPath() hasSuffix:@"/GlobalDefaults/Display.plist"],
             "the system file is GlobalDefaults/Display.plist");
    END_SET("system-wide scale")

    [arp release];
    return 0;
}
