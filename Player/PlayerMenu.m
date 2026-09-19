/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "PlayerMenu.h"

static NSString *functionKey(unichar key)
{
    return [NSString stringWithCharacters:&key length:1];
}

@implementation PlayerMenu

+ (NSMenuItem *)addItemTo:(NSMenu *)menu
                    title:(NSString *)title
                   action:(SEL)action
                      key:(NSString *)key
                   target:(id)target
{
    NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:title action:action keyEquivalent:key];
    [item setTarget:target];
    return item;
}

+ (NSMenu *)addSubmenu:(NSString *)title to:(NSMenu *)mainMenu
{
    NSMenuItem *holder = (NSMenuItem *)[mainMenu addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
    [holder setSubmenu:menu];
    return menu;
}

+ (NSMenu *)mainMenuWithTarget:(id)target
{
    NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@"Player"] autorelease];
    NSMenuItem *item;

    NSMenu *app = [self addSubmenu:@"Player" to:mainMenu];
    [self addItemTo:app title:@"About Player"
             action:@selector(orderFrontStandardAboutPanel:) key:@"" target:nil];
    [app addItem:[NSMenuItem separatorItem]];
    [self addItemTo:app title:@"Preferences..."
             action:@selector(openPreferences:) key:@"," target:target];
    [app addItem:[NSMenuItem separatorItem]];
    [self addItemTo:app title:@"Hide Player" action:@selector(hide:) key:@"h" target:nil];
    item = [self addItemTo:app title:@"Hide Others"
                    action:@selector(hideOtherApplications:) key:@"h" target:nil];
    [item setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
    [self addItemTo:app title:@"Show All"
             action:@selector(unhideAllApplications:) key:@"" target:nil];
    [app addItem:[NSMenuItem separatorItem]];
    [self addItemTo:app title:@"Quit Player" action:@selector(terminate:) key:@"q" target:nil];

    NSMenu *file = [self addSubmenu:@"File" to:mainMenu];
    [self addItemTo:file title:@"Open..." action:@selector(openFile:) key:@"o" target:target];
    [self addItemTo:file title:@"Open URL..." action:@selector(openURL:) key:@"u" target:target];
    [file addItem:[NSMenuItem separatorItem]];
    [self addItemTo:file title:@"Close Window"
             action:@selector(performClose:) key:@"w" target:nil];

    // For the text fields: radio search and the URL dialog
    NSMenu *edit = [self addSubmenu:@"Edit" to:mainMenu];
    [self addItemTo:edit title:@"Undo" action:@selector(undo:) key:@"z" target:nil];
    [self addItemTo:edit title:@"Redo" action:@selector(redo:) key:@"Z" target:nil];
    [edit addItem:[NSMenuItem separatorItem]];
    [self addItemTo:edit title:@"Cut" action:@selector(cut:) key:@"x" target:nil];
    [self addItemTo:edit title:@"Copy" action:@selector(copy:) key:@"c" target:nil];
    [self addItemTo:edit title:@"Paste" action:@selector(paste:) key:@"v" target:nil];
    [self addItemTo:edit title:@"Select All" action:@selector(selectAll:) key:@"a" target:nil];

    // Space plays and pauses in the window itself: as a menu shortcut
    // without Command it would also fire while typing in a text field.
    NSMenu *playback = [self addSubmenu:@"Playback" to:mainMenu];
    [self addItemTo:playback title:@"Play" action:@selector(playPause:) key:@"" target:target];
    [self addItemTo:playback title:@"Stop" action:@selector(stop:) key:@"." target:target];
    [playback addItem:[NSMenuItem separatorItem]];
    [self addItemTo:playback title:@"Next Track" action:@selector(nextTrack:)
                key:functionKey(NSRightArrowFunctionKey) target:target];
    [self addItemTo:playback title:@"Previous Track" action:@selector(previousTrack:)
                key:functionKey(NSLeftArrowFunctionKey) target:target];
    [playback addItem:[NSMenuItem separatorItem]];
    [self addItemTo:playback title:@"Increase Volume" action:@selector(increaseVolume:)
                key:functionKey(NSUpArrowFunctionKey) target:target];
    [self addItemTo:playback title:@"Decrease Volume" action:@selector(decreaseVolume:)
                key:functionKey(NSDownArrowFunctionKey) target:target];
    [self addItemTo:playback title:@"Mute" action:@selector(toggleMute:) key:@"" target:target];
    [playback addItem:[NSMenuItem separatorItem]];
    [self addItemTo:playback title:@"Repeat" action:@selector(toggleRepeat:) key:@"R" target:target];
    [self addItemTo:playback title:@"Shuffle" action:@selector(toggleShuffle:) key:@"S" target:target];

    NSMenu *view = [self addSubmenu:@"View" to:mainMenu];
    [self addItemTo:view title:@"Enter Full Screen"
             action:@selector(toggleFullscreen:) key:@"f" target:target];

    NSMenu *radio = [self addSubmenu:@"Radio" to:mainMenu];
    [self addItemTo:radio title:@"Internet Radio"
             action:@selector(toggleRadioMode:) key:@"r" target:target];
    item = (NSMenuItem *)[NSMenuItem separatorItem];
    [item setTag:PlayerMenuStationListTag];
    [radio addItem:item];

    return mainMenu;
}

@end
