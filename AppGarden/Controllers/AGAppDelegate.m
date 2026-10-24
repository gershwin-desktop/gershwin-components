/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGAppDelegate.h"
#import "AGMainWindowController.h"
#import "AGFeedLoader.h"
#import "AGImageCache.h"
#import "AGInstaller.h"
#import "AGInstallRegistry.h"

static NSString *const kAGHelpURLString =
    @"https://github.com/gershwin-desktop/gershwin-components/tree/dev/AppGarden";

@implementation AGAppDelegate
{
  AGFeedLoader *_feedLoader;
  AGImageCache *_imageCache;
  AGInstaller *_installer;
  AGMainWindowController *_mainWindowController;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
  (void)notification;
  [self buildMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  (void)notification;
  _feedLoader = [[AGFeedLoader alloc] init];
  _imageCache = [[AGImageCache alloc] init];
  _installer = [[AGInstaller alloc] initWithRegistry:[[AGInstallRegistry alloc] init]];
  _mainWindowController = [[AGMainWindowController alloc] initWithFeedLoader:_feedLoader
                                                                  imageCache:_imageCache
                                                                   installer:_installer];
  [_mainWindowController showWindow:self];
  [_mainWindowController loadCatalog];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  (void)sender;
  return YES;
}

#pragma mark - Menu

- (NSMenu *)submenuTitled:(NSString *)title inMenu:(NSMenu *)menu
{
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
  NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
  [item setSubmenu:submenu];
  [menu addItem:item];
  return submenu;
}

- (NSMenuItem *)addItemTitled:(NSString *)title
                       action:(SEL)action
                          key:(NSString *)key
                    modifiers:(NSUInteger)modifiers
                       toMenu:(NSMenu *)menu
{
  NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle:title action:action keyEquivalent:key];
  [item setKeyEquivalentModifierMask:modifiers];
  return item;
}

- (void)buildMenu
{
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

  NSMenu *appMenu = [self submenuTitled:NSLocalizedString(@"AppGarden", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"About AppGarden", @"")
               action:@selector(orderFrontStandardAboutPanel:) key:@"" modifiers:0 toMenu:appMenu];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTitled:NSLocalizedString(@"Hide AppGarden", @"")
               action:@selector(hide:) key:@"h" modifiers:NSCommandKeyMask toMenu:appMenu];
  [self addItemTitled:NSLocalizedString(@"Hide Others", @"")
               action:@selector(hideOtherApplications:) key:@"h"
            modifiers:(NSCommandKeyMask | NSAlternateKeyMask) toMenu:appMenu];
  [self addItemTitled:NSLocalizedString(@"Show All", @"")
               action:@selector(unhideAllApplications:) key:@"" modifiers:0 toMenu:appMenu];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTitled:NSLocalizedString(@"Quit AppGarden", @"")
               action:@selector(terminate:) key:@"q" modifiers:NSCommandKeyMask toMenu:appMenu];

  NSMenu *fileMenu = [self submenuTitled:NSLocalizedString(@"File", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"Close Window", @"")
               action:@selector(performClose:) key:@"w" modifiers:NSCommandKeyMask toMenu:fileMenu];

  NSMenu *editMenu = [self submenuTitled:NSLocalizedString(@"Edit", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"Cut", @"")
               action:@selector(cut:) key:@"x" modifiers:NSCommandKeyMask toMenu:editMenu];
  [self addItemTitled:NSLocalizedString(@"Copy", @"")
               action:@selector(copy:) key:@"c" modifiers:NSCommandKeyMask toMenu:editMenu];
  [self addItemTitled:NSLocalizedString(@"Paste", @"")
               action:@selector(paste:) key:@"v" modifiers:NSCommandKeyMask toMenu:editMenu];
  [self addItemTitled:NSLocalizedString(@"Select All", @"")
               action:@selector(selectAll:) key:@"a" modifiers:NSCommandKeyMask toMenu:editMenu];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTitled:NSLocalizedString(@"Find", @"")
               action:@selector(focusSearchField:) key:@"f" modifiers:NSCommandKeyMask toMenu:editMenu];

  NSMenu *viewMenu = [self submenuTitled:NSLocalizedString(@"View", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"Discover", @"")
               action:@selector(showDiscover:) key:@"1" modifiers:NSCommandKeyMask toMenu:viewMenu];
  [self addItemTitled:NSLocalizedString(@"Downloaded", @"")
               action:@selector(showInstalled:) key:@"2" modifiers:NSCommandKeyMask toMenu:viewMenu];
  [viewMenu addItem:[NSMenuItem separatorItem]];
  [self addItemTitled:NSLocalizedString(@"Reload Catalog", @"")
               action:@selector(reloadCatalog:) key:@"r" modifiers:NSCommandKeyMask toMenu:viewMenu];

  NSMenu *goMenu = [self submenuTitled:NSLocalizedString(@"Go", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"Back", @"")
               action:@selector(goBack:) key:@"[" modifiers:NSCommandKeyMask toMenu:goMenu];

  NSMenu *windowMenu = [self submenuTitled:NSLocalizedString(@"Window", @"") inMenu:mainMenu];
  [self addItemTitled:NSLocalizedString(@"Minimize", @"")
               action:@selector(performMiniaturize:) key:@"m" modifiers:NSCommandKeyMask toMenu:windowMenu];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [NSApp setWindowsMenu:windowMenu];

  NSMenu *helpMenu = [self submenuTitled:NSLocalizedString(@"Help", @"") inMenu:mainMenu];
  NSMenuItem *help = [self addItemTitled:NSLocalizedString(@"AppGarden Help", @"")
                                  action:@selector(openHelp:) key:@"" modifiers:0 toMenu:helpMenu];
  [help setTarget:self];

  [NSApp setMainMenu:mainMenu];
}

- (void)openHelp:(id)sender
{
  (void)sender;
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kAGHelpURLString]];
}

@end
