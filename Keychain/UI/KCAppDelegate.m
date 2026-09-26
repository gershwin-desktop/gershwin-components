/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "KCAppDelegate.h"
#import "KCKeychainWindowController.h"
#import "KCPasswordPanel.h"
#import "KCDBusConnection.h"
#import "KCKeyring.h"

/* Set by the D-Bus activation file: the service was started because a
 * client needs it, so the app runs without opening its window. */
static NSString * const kServiceLaunchDefault = @"KCServiceLaunch";

@implementation KCAppDelegate
{
  KCKeyring *_keyring;
  KCDBusConnection *_bus;
  KCSecretService *_service;
  KCKeychainWindowController *_windowController;
}

static void KCAddItem(NSMenu *menu, NSString *title, SEL action, NSString *key)
{
  [menu addItemWithTitle: title action: action keyEquivalent: key];
}

static NSMenu *KCSubmenu(NSMenu *main, NSString *title)
{
  id<NSMenuItem> item = [main addItemWithTitle: title action: NULL keyEquivalent: @""];
  NSMenu *menu = [[NSMenu alloc] initWithTitle: title];
  [main setSubmenu: menu forItem: item];
  return menu;
}

- (void) buildMenu
{
  NSMenu *main = [[NSMenu alloc] initWithTitle: @"Keychain"];
  NSMenu *m;

  m = KCSubmenu(main, @"Keychain");
  KCAddItem(m, @"About Keychain", @selector(orderFrontStandardAboutPanel:), @"");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Hide Keychain", @selector(hide:), @"h");
  KCAddItem(m, @"Hide Others", @selector(hideOtherApplications:), @"");
  KCAddItem(m, @"Show All", @selector(unhideAllApplications:), @"");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Quit Keychain", @selector(terminate:), @"q");

  m = KCSubmenu(main, @"File");
  KCAddItem(m, @"New Password Item...", @selector(newItem:), @"n");
  KCAddItem(m, @"New Keychain...", @selector(newKeychain:), @"N");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Get Info", @selector(showInspector:), @"i");
  KCAddItem(m, @"Delete Item", @selector(deleteItem:), @"");
  KCAddItem(m, @"Delete Keychain...", @selector(deleteKeychain:), @"");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Close Window", @selector(performClose:), @"w");

  m = KCSubmenu(main, @"Edit");
  KCAddItem(m, @"Cut", @selector(cut:), @"x");
  KCAddItem(m, @"Copy", @selector(copy:), @"c");
  KCAddItem(m, @"Paste", @selector(paste:), @"v");
  KCAddItem(m, @"Select All", @selector(selectAll:), @"a");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Copy Password to Clipboard", @selector(copyPassword:), @"C");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Find", @selector(performFindPanelAction:), @"f");

  m = KCSubmenu(main, @"Keychains");
  KCAddItem(m, @"Unlock Keychain", @selector(toggleLock:), @"l");
  KCAddItem(m, @"Lock All Keychains", @selector(lockAll:), @"L");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Make Keychain Default", @selector(makeDefault:), @"");

  m = KCSubmenu(main, @"Window");
  KCAddItem(m, @"Keychain", @selector(showKeychainWindow:), @"1");
  [m addItem: [NSMenuItem separatorItem]];
  KCAddItem(m, @"Minimize", @selector(performMiniaturize:), @"m");
  [NSApp setWindowsMenu: m];

  [NSApp setMainMenu: main];
}

/* Nothing here can be worked around: without its keyrings or its bus
 * name the app would silently lose or split the user's credentials. */
- (void) failWithTitle: (NSString *)title error: (NSError *)error
{
  NSLog(@"Keychain: %@: %@", title, [error localizedDescription]);
  NSRunAlertPanel(title, @"%@", @"Quit", nil, nil, [error localizedDescription]);
  exit(EXIT_FAILURE);
}

- (void) applicationWillFinishLaunching: (NSNotification *)n
{
  [self buildMenu];
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  NSError *error = nil;

  _keyring = [[KCKeyring alloc] initWithDirectory: [KCKeyring defaultDirectory]];
  if (![_keyring load: &error])
    [self failWithTitle: @"The keychains could not be read" error: error];

  _bus = [[KCDBusConnection alloc] initWithSessionBus: &error
    runLoopModes: [NSArray arrayWithObjects: NSDefaultRunLoopMode,
                    NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode, nil]];
  if (_bus == nil)
    [self failWithTitle: @"No session bus" error: error];
  _service = [[KCSecretService alloc] initWithKeyring: _keyring connection: _bus
                                            requester: self];
  if (![_service start: &error])
    [self failWithTitle: @"Keychain cannot provide the Secret Service" error: error];

  _windowController = [[KCKeychainWindowController alloc] initWithKeyring: _keyring];
  if (![[NSUserDefaults standardUserDefaults] boolForKey: kServiceLaunchDefault])
    [self showKeychainWindow: nil];
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)app
{
  /* Applications keep talking to the service after the window is closed. */
  return NO;
}

- (BOOL) applicationShouldHandleReopen: (NSApplication *)app hasVisibleWindows: (BOOL)flag
{
  [self showKeychainWindow: nil];
  return YES;
}

- (IBAction) showKeychainWindow: (id)sender
{
  [_windowController showWindow: sender];
  [[_windowController window] makeKeyAndOrderFront: sender];
}

#pragma mark Actions of the keychain window

/* The keychain commands must work while the Item Info or another panel is
 * the key window, whose responder chain ends at this delegate without
 * passing the keychain window's controller. */
static BOOL KCIsKeychainAction(SEL sel)
{
  static NSSet *names = nil;

  if (names == nil)
    names = [NSSet setWithObjects: @"toggleLock:", @"lockAll:", @"newItem:",
      @"deleteItem:", @"newKeychain:", @"deleteKeychain:", @"makeDefault:",
      @"showInspector:", @"copyPassword:", @"validateMenuItem:", nil];
  return [names containsObject: NSStringFromSelector(sel)];
}

- (BOOL) respondsToSelector: (SEL)sel
{
  if (KCIsKeychainAction(sel) && _windowController != nil)
    return YES;
  return [super respondsToSelector: sel];
}

- (id) forwardingTargetForSelector: (SEL)sel
{
  return KCIsKeychainAction(sel) ? _windowController : nil;
}

#pragma mark KCPasswordRequester

- (id) requestPasswordWithTitle: (NSString *)title
                        message: (NSString *)message
                    newPassword: (BOOL)isNew
                      validator: (NSString *(^)(NSString *password))validator
                     completion: (void (^)(BOOL accepted))completion
{
  KCPasswordPanel *panel = [[KCPasswordPanel alloc]
    initWithTitle: title message: message newPassword: isNew askName: NO
        validator: ^NSString *(KCPasswordPanel *p) { return validator([p password]); }
       completion: completion];
  [panel show];
  return panel;
}

- (void) cancelPasswordRequest: (id)request
{
  [(KCPasswordPanel *)request close];
}

@end
