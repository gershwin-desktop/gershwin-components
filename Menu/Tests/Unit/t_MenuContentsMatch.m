/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* An app that announces a new menu layout (dbusmenu LayoutUpdated) is only
   worth a menu bar rebuild when something the user can see changed: Electron
   renumbers its whole menu every few seconds without changing a single
   title.  MenuContentsMatch decides that.  NSMenu creates its panel at once,
   so this needs NSApp and a DISPLAY (a private Xvfb); the plain GNUstep theme
   keeps the Eau theme from talking to the running Menu.app. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "MenuContentsMatch.h"

static NSMenu *editMenu(NSString *copyTitle, BOOL pasteEnabled, NSInteger wrapState)
{
    NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [edit addItemWithTitle:copyTitle action:NULL keyEquivalent:@""];
    NSMenuItem *paste = (NSMenuItem *)[edit addItemWithTitle:@"Paste" action:NULL keyEquivalent:@""];
    [paste setEnabled:pasteEnabled];
    NSMenuItem *wrap = (NSMenuItem *)[edit addItemWithTitle:@"Word Wrap" action:NULL keyEquivalent:@""];
    [wrap setState:wrapState];
    NSMenu *bar = [[[NSMenu alloc] initWithTitle:@"Root"] autorelease];
    NSMenuItem *top = (NSMenuItem *)[bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    [top setSubmenu:edit];
    [bar addItemWithTitle:@"Help" action:NULL keyEquivalent:@""];
    return bar;
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *arguments = [NSMutableDictionary dictionaryWithDictionary:
        [defaults volatileDomainForName:NSArgumentDomain]];
    [arguments setObject:@"GNUstep" forKey:@"GSTheme"];
    [defaults removeVolatileDomainForName:NSArgumentDomain];
    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
    [NSApplication sharedApplication];
    START_SET("MenuContentsMatch");

    NSMenu *shown = editMenu(@"Copy", YES, NSOffState);
    NSMenu *renumbered = editMenu(@"Copy", YES, NSOffState);
    [[[[renumbered itemAtIndex:0] submenu] itemAtIndex:0] setTag:4711];
    PASS(MenuContentsMatch(shown, renumbered),
         "new ids alone are no visible change");

    PASS(!MenuContentsMatch(shown, editMenu(@"Copy Path", YES, NSOffState)),
         "a changed title in a submenu is a visible change");
    PASS(!MenuContentsMatch(shown, editMenu(@"Copy", NO, NSOffState)),
         "an item that became disabled is a visible change");
    PASS(!MenuContentsMatch(shown, editMenu(@"Copy", YES, NSOnState)),
         "a changed check mark is a visible change");

    NSMenu *longer = editMenu(@"Copy", YES, NSOffState);
    [[[longer itemAtIndex:0] submenu] addItemWithTitle:@"Select All" action:NULL keyEquivalent:@""];
    PASS(!MenuContentsMatch(shown, longer), "an added item is a visible change");

    NSMenu *noSub = editMenu(@"Copy", YES, NSOffState);
    [[noSub itemAtIndex:0] setSubmenu:nil];
    PASS(!MenuContentsMatch(shown, noSub), "a submenu that went away is a visible change");

    PASS(!MenuContentsMatch(shown, nil) && !MenuContentsMatch(nil, shown),
         "a missing menu never matches");

    END_SET("MenuContentsMatch");
    [pool release];
    return 0;
}
