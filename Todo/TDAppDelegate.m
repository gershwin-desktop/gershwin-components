/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "TDAppDelegate.h"
#import "TDMainWindowController.h"
#import "TDPreferencesWindowController.h"
#import "TDStore.h"

@implementation TDAppDelegate

- (void)applicationDidFinishLaunching: (NSNotification *)notification
{
  NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle: @"MainMenu"] autorelease];
  NSMenuItem *appMenuItem = [[[NSMenuItem alloc] initWithTitle: @"Todo" action: NULL keyEquivalent: @""] autorelease];
  NSMenu *appMenu = [[[NSMenu alloc] initWithTitle: @"Todo"] autorelease];
  NSMenuItem *editMenuItem = [[[NSMenuItem alloc] initWithTitle: @"Edit" action: NULL keyEquivalent: @""] autorelease];
  NSMenu *editMenu = [[[NSMenu alloc] initWithTitle: @"Edit"] autorelease];
  id <NSMenuItem> item;
  NSError *pullError = nil;

  [appMenuItem setSubmenu: appMenu];
  [mainMenu addItem: appMenuItem];

  item = [appMenu addItemWithTitle: @"About Todo" action: @selector(orderFrontStandardAboutPanel:) keyEquivalent: @""];
  [item setTarget: self];
  item = [appMenu addItemWithTitle: @"Preferences..." action: @selector(showPreferences:) keyEquivalent: @","];
  [item setTarget: self];
  [appMenu addItem: [NSMenuItem separatorItem]];
  item = [appMenu addItemWithTitle: @"Quit Todo" action: @selector(terminate:) keyEquivalent: @"q"];
  [item setTarget: NSApp];

  [editMenuItem setSubmenu: editMenu];
  [mainMenu addItem: editMenuItem];
  [editMenu addItemWithTitle: @"Cut" action: @selector(cut:) keyEquivalent: @"x"];
  [editMenu addItemWithTitle: @"Copy" action: @selector(copy:) keyEquivalent: @"c"];
  [editMenu addItemWithTitle: @"Paste" action: @selector(paste:) keyEquivalent: @"v"];
  [editMenu addItemWithTitle: @"Select All" action: @selector(selectAll:) keyEquivalent: @"a"];

  [NSApp setMainMenu: mainMenu];

  _mainWindowController = [[TDMainWindowController alloc] init];
  [_mainWindowController showWindow];

  /* A first pull is best-effort: without a gist ID/token yet (first
   * launch) this just leaves the status line saying so, and the local
   * cache (if any) is already what -init loaded. */
  [[TDStore sharedStore] pullWithError: &pullError];
}

- (void)applicationWillTerminate: (NSNotification *)notification
{
  [_mainWindowController release];
  _mainWindowController = nil;
}

- (void)showPreferences: (id)sender
{
  [[TDPreferencesWindowController sharedController] showWindow];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)app
{
  return YES;
}

@end
