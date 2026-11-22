/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "KeyboardBackend.h"

static NSString *const kSetxkbmapLocal = @"/usr/local/bin/setxkbmap";
static NSString *const kSetxkbmapSystem = @"/usr/bin/setxkbmap";
static NSString *const kKeyboardDomain = @"KeyboardPreferences";
NSString *const KeyboardBackendPreferencesDidChangeNotification = @"io.github.gershwin-desktop.KeyboardPreferencesDidChange";
static NSString *const kMenuLayoutsKey = @"menuLayouts";

/* The part of Menu's configuration server this needs. */
@protocol KeyboardMenuConfigProtocol
- (BOOL)updateEnabledExtras:(NSArray *)identifiers;
@end

static NSString *const kKeyboardExtraIdentifier = @"io.github.gershwin-desktop.menuextra.keyboard";

/* Identifiers of every extra installed next to Menu, for the case that the
   user never saved a set: Menu then shows all of them, and switching one off
   means saying which others stay. */
static NSArray *InstalledExtraIdentifiers(void)
{
    NSMutableArray *identifiers = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/System/Library/MenuExtras";
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if (![[item pathExtension] isEqualToString:@"gsmenuextra"]) {
            continue;
        }
        NSString *plist = [[dir stringByAppendingPathComponent:item]
            stringByAppendingPathComponent:@"Resources/Info-gnustep.plist"];
        NSString *identifier = [[NSDictionary dictionaryWithContentsOfFile:plist] objectForKey:@"CFBundleIdentifier"];
        if (identifier != nil) {
            [identifiers addObject:identifier];
        }
    }
    return identifiers;
}

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

+ (NSDictionary *)availableLayouts:(NSDictionary **)variantsByLayout
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *possiblePaths = [NSArray arrayWithObjects:
                              @"/usr/share/X11/xkb/rules/base.lst",
                              @"/usr/local/share/X11/xkb/rules/base.lst",
                              nil];
    NSString *lstPath = nil;
    for (NSString *path in possiblePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            lstPath = path;
            break;
        }
    }
    NSError *error = nil;
    NSString *contents = lstPath ? [NSString stringWithContentsOfFile:lstPath encoding:NSUTF8StringEncoding error:&error] : nil;

    NSMutableDictionary *layoutMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *variantMap = [NSMutableDictionary dictionary];

    if (contents) {
        BOOL inLayout = NO;
        BOOL inVariant = NO;
        NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

        for (NSString *line in lines) {
            NSString *trim = [line stringByTrimmingCharactersInSet:ws];
            if ([trim length] == 0) {
                continue;
            }

            if ([trim hasPrefix:@"! "]) {
                inLayout = [trim hasPrefix:@"! layout"];
                inVariant = [trim hasPrefix:@"! variant"];
                continue;
            }

            if (inLayout) {
                NSRange space = [trim rangeOfString:@" "];
                if (space.location == NSNotFound) {
                    continue;
                }
                NSString *code = [[trim substringToIndex:space.location] stringByTrimmingCharactersInSet:ws];
                NSString *desc = [[trim substringFromIndex:space.location] stringByTrimmingCharactersInSet:ws];
                if ([code length] > 0) {
                    [layoutMap setObject:(desc.length ? desc : code) forKey:code];
                }
                continue;
            }

            if (inVariant) {
                NSRange colon = [trim rangeOfString:@":"];
                if (colon.location == NSNotFound) {
                    continue;
                }
                NSString *lhs = [[trim substringToIndex:colon.location] stringByTrimmingCharactersInSet:ws];
                NSString *rhs = [[trim substringFromIndex:(colon.location + 1)] stringByTrimmingCharactersInSet:ws];

                NSArray *parts = [lhs componentsSeparatedByCharactersInSet:ws];
                if ([parts count] < 2) {
                    continue;
                }
                NSString *variantCode = [parts objectAtIndex:0];
                NSString *layoutCode = [parts lastObject];

                if ([variantCode length] == 0 || [layoutCode length] == 0) {
                    continue;
                }

                NSMutableArray *list = [variantMap objectForKey:layoutCode];
                if (!list) {
                    list = [NSMutableArray array];
                    [variantMap setObject:list forKey:layoutCode];
                }
                NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:variantCode, @"code", (rhs.length ? rhs : variantCode), @"description", nil];
                [list addObject:entry];
            }
        }
    }

    if (variantsByLayout) {
        *variantsByLayout = variantMap;
    }
    return layoutMap;
}

+ (NSDictionary *)savedPreferences
{
    /* Read the file itself: the pane and the long-running Menu are different
       processes, and NSUserDefaults never re-reads a persistent domain it has
       already cached, so Menu would keep showing what it saw first. */
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [[library stringByAppendingPathComponent:@"Preferences"]
        stringByAppendingPathComponent:[kKeyboardDomain stringByAppendingPathExtension:@"plist"]];
    NSDictionary *domain = [NSDictionary dictionaryWithContentsOfFile:path];
    return domain ? domain : @{};
}

+ (void)persistLayout:(NSString *)layout variant:(NSString *)variant
{
    NSMutableDictionary *domain = [[self savedPreferences] mutableCopy];
    [domain setObject:layout forKey:@"layout"];
    if ([variant length] > 0) {
        [domain setObject:variant forKey:@"variant"];
    } else {
        [domain removeObjectForKey:@"variant"];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kKeyboardDomain];
    [defaults synchronize];
    [self announcePreferencesChange];
}

+ (NSArray *)menuLayouts
{
    NSArray *list = [[self savedPreferences] objectForKey:kMenuLayoutsKey];
    return list ? list : @[];
}

+ (void)setMenuLayouts:(NSArray *)menuLayouts
{
    NSMutableDictionary *domain = [[self savedPreferences] mutableCopy];
    [domain setObject:menuLayouts forKey:kMenuLayoutsKey];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kKeyboardDomain];
    [defaults synchronize];
    [self announcePreferencesChange];
}

+ (BOOL)menuLayouts:(NSArray *)menuLayouts containLayout:(NSString *)layout variant:(NSString *)variant
{
    for (NSDictionary *entry in menuLayouts) {
        NSString *entryVariant = [entry objectForKey:@"variant"];
        if ([[entry objectForKey:@"layout"] isEqualToString:layout]
            && ((entryVariant.length == 0 && variant.length == 0)
                || [entryVariant isEqualToString:variant])) {
            return YES;
        }
    }
    return NO;
}

+ (void)syncKeyboardMenuExtraWithMenuLayouts
{
    BOOL wanted = [[self menuLayouts] count] >= 2;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *domain = [[defaults persistentDomainForName:@"Menu"] mutableCopy];
    if (domain == nil) {
        domain = [NSMutableDictionary dictionary];
    }
    NSArray *saved = [domain objectForKey:@"GSMenuExtraEnabled"];
    if (![saved isKindOfClass:[NSArray class]] || [saved count] == 0) {
        if (wanted) {
            return;
        }
        saved = InstalledExtraIdentifiers();
    }
    if ([saved containsObject:kKeyboardExtraIdentifier] == wanted) {
        return;
    }
    NSMutableArray *enabled = [saved mutableCopy];
    if (wanted) {
        [enabled addObject:kKeyboardExtraIdentifier];
    } else {
        [enabled removeObject:kKeyboardExtraIdentifier];
    }
    [domain setObject:enabled forKey:@"GSMenuExtraEnabled"];
    /* Menu's own saved order lists the enabled extras too. */
    NSMutableArray *order = [[domain objectForKey:@"GSMenuExtraOrder"] mutableCopy];
    if (order != nil) {
        [order removeObject:kKeyboardExtraIdentifier];
        if (wanted) {
            [order addObject:kKeyboardExtraIdentifier];
        }
        [domain setObject:order forKey:@"GSMenuExtraOrder"];
    }
    [defaults setPersistentDomain:domain forName:@"Menu"];
    [defaults synchronize];

    @try {
        id<KeyboardMenuConfigProtocol> menu = (id<KeyboardMenuConfigProtocol>)
            [NSConnection rootProxyForConnectionWithRegisteredName:
                @"io.github.gershwin-desktop.MenuExtraConfigServer" host:nil];
        [menu updateEnabledExtras:enabled];
    } @catch (NSException *e) {
        NSLog(@"KeyboardBackend: could not tell Menu to reload its extras: %@", e);
    }
}

+ (void)announcePreferencesChange
{
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:KeyboardBackendPreferencesDidChangeNotification
                      object:nil];
}

@end
