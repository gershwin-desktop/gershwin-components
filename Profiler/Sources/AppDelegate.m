/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AppDelegate.h"
#import "PRProfilerWindowController.h"

@implementation AppDelegate

- (void)buildMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Profiler"];

    id<NSMenuItem> infoItem = [menu addItemWithTitle:@"Info"
                                            action:NULL
                                     keyEquivalent:@""];
    NSMenu *info = [[NSMenu alloc] initWithTitle:@"Info"];
    [info addItemWithTitle:@"About Profiler"
                    action:@selector(orderFrontStandardInfoPanel:)
             keyEquivalent:@""];
    [menu setSubmenu:info forItem:infoItem];

    id<NSMenuItem> profileItem = [menu addItemWithTitle:@"Profile"
                                               action:NULL
                                        keyEquivalent:@""];
    NSMenu *profile = [[NSMenu alloc] initWithTitle:@"Profile"];
    [[profile addItemWithTitle:@"Record..."
                        action:@selector(startRecording:)
                 keyEquivalent:@"r"] setTarget:self];
    [[profile addItemWithTitle:@"Stop"
                        action:@selector(stopRecording:)
                 keyEquivalent:@"."] setTarget:self];
    [profile addItem:[NSMenuItem separatorItem]];
    [[profile addItemWithTitle:@"Open Folded Stacks..."
                        action:@selector(openFoldedStacks:)
                 keyEquivalent:@"o"] setTarget:self];
    [[profile addItemWithTitle:@"Save Folded Stacks..."
                        action:@selector(exportFoldedStacks:)
                 keyEquivalent:@"s"] setTarget:self];
    [menu setSubmenu:profile forItem:profileItem];

    id<NSMenuItem> editItem = [menu addItemWithTitle:@"Edit"
                                            action:NULL
                                     keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All"
                    action:@selector(selectAll:)
             keyEquivalent:@"a"];
    [menu setSubmenu:edit forItem:editItem];

    id<NSMenuItem> windowsItem = [menu addItemWithTitle:@"Windows"
                                               action:NULL
                                        keyEquivalent:@""];
    NSMenu *windows = [[NSMenu alloc] initWithTitle:@"Windows"];
    [windows addItemWithTitle:@"Arrange in Front"
                       action:@selector(arrangeInFront:)
                keyEquivalent:@""];
    [windows addItemWithTitle:@"Miniaturize Window"
                       action:@selector(performMiniaturize:)
                keyEquivalent:@"m"];
    [windows addItemWithTitle:@"Close Window"
                       action:@selector(performClose:)
                keyEquivalent:@"w"];
    [menu setSubmenu:windows forItem:windowsItem];
    [NSApp setWindowsMenu:windows];

    id<NSMenuItem> servicesItem = [menu addItemWithTitle:@"Services"
                                                action:NULL
                                         keyEquivalent:@""];
    NSMenu *services = [[NSMenu alloc] initWithTitle:@"Services"];
    [menu setSubmenu:services forItem:servicesItem];
    [NSApp setServicesMenu:services];

    [menu addItemWithTitle:@"Hide" action:@selector(hide:) keyEquivalent:@"h"];
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

    [NSApp setMainMenu:menu];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [self buildMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    _windowController = [[PRProfilerWindowController alloc] init];
    [_windowController showWindow:self];
    [[_windowController window] makeKeyAndOrderFront:self];
    [self openFileFromCommandLine];
}

/* "Profiler recording.folded" on the command line, and a file opened from
   the workspace, both land here. */
- (BOOL)application:(NSApplication *)application openFile:(NSString *)path
{
    (void)application;
    return [_windowController openProfileAtPath:path];
}

- (void)openFileFromCommandLine
{
    NSArray *arguments = [[NSProcessInfo processInfo] arguments];
    NSFileManager *manager = [NSFileManager defaultManager];

    for (NSUInteger i = 1; i < [arguments count]; i++) {
        NSString *argument = [arguments objectAtIndex:i];
        if ([argument hasPrefix:@"-"])
            continue;
        if ([manager isReadableFileAtPath:argument]) {
            [_windowController openProfileAtPath:argument];
            return;
        }
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    (void)notification;
    [_windowController stopEverything];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)startRecording:(id)sender
{
    [_windowController startRecording:sender];
}

- (void)stopRecording:(id)sender
{
    [_windowController stopRecording:sender];
}

- (void)openFoldedStacks:(id)sender
{
    [_windowController openFoldedStacks:sender];
}

- (void)exportFoldedStacks:(id)sender
{
    [_windowController exportFoldedStacks:sender];
}

@end
