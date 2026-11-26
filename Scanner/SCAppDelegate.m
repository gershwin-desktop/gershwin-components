/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCAppDelegate.h"
#import "SCScanner.h"
#import "SCDeviceChooser.h"
#import "SCScanWindow.h"
#import "SCPasswordPanel.h"
#import "SCPreferences.h"
#import "SCPermissionCheck.h"
#import "SCSoftwareInstaller.h"
#import "SCSaneLibrary.h"
#import "SCIPPUSB.h"
#include <unistd.h>

@interface SCAppDelegate () <SCDeviceChooserDelegate>
@end

@implementation SCAppDelegate
{
  SCDeviceChooser *_chooser;
  SCScanWindow *_scanWindow;
  SCPreferences *_preferences;
  NSString *_requestedDevice;
  BOOL _firstSearch;
  BOOL _switching;
  BOOL _opening;
  /* At launch the last scanner is opened without asking first */
  BOOL _openingLastDevice;
  BOOL _saneReady;
  /* USB scanning (ipp-usb) is offered once per session */
  BOOL _usbScanningOffered;
}

#pragma mark Menu

- (NSMenu *) addMenu: (NSString *)title to: (NSMenu *)main
{
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: title action: NULL
                                         keyEquivalent: @""];
  NSMenu *menu = [[NSMenu alloc] initWithTitle: title];

  [item setSubmenu: menu];
  [main addItem: item];
  return menu;
}

- (void) add: (NSString *)title action: (SEL)action key: (NSString *)key
          to: (NSMenu *)menu
{
  NSMenuItem *item = (NSMenuItem *)[menu addItemWithTitle: title action: action
                                                keyEquivalent: key];

  /* Scan actions go through here, so they also work while another window is key */
  if ([self respondsToSelector: action])
    {
      [item setTarget: self];
    }
}

- (void) setupMenu
{
  NSMenu *main = [[NSMenu alloc] initWithTitle: @"Scanner"];
  NSMenu *m;

  m = [self addMenu: @"Scanner" to: main];
  [self add: @"About Scanner" action: @selector(orderFrontStandardAboutPanel:)
        key: @"" to: m];
  [self add: @"Preferences..." action: @selector(showPreferences:) key: @"," to: m];
  [m addItem: [NSMenuItem separatorItem]];
  [self add: @"Hide Scanner" action: @selector(hide:) key: @"h" to: m];
  [self add: @"Quit Scanner" action: @selector(terminate:) key: @"q" to: m];

  m = [self addMenu: @"File" to: main];
  [self add: @"Choose Scanner..." action: @selector(chooseScanner:) key: @"O" to: m];
  [self add: @"Show Saved File" action: @selector(showSavedFile:) key: @"" to: m];
  [self add: @"Close" action: @selector(performClose:) key: @"w" to: m];

  m = [self addMenu: @"Edit" to: main];
  [self add: @"Cut" action: @selector(cut:) key: @"x" to: m];
  [self add: @"Copy" action: @selector(copy:) key: @"c" to: m];
  [self add: @"Paste" action: @selector(paste:) key: @"v" to: m];
  [self add: @"Delete" action: @selector(delete:) key: @"" to: m];
  [self add: @"Select All" action: @selector(selectAll:) key: @"a" to: m];

  m = [self addMenu: @"Scan" to: main];
  [self add: @"Preview" action: @selector(preview:) key: @"P" to: m];
  [self add: @"Scan" action: @selector(scan:) key: @"S" to: m];
  [self add: @"Cancel Scan" action: @selector(cancelScan:) key: @"." to: m];
  [m addItem: [NSMenuItem separatorItem]];
  [self add: @"Save Pages" action: @selector(savePages:) key: @"s" to: m];
  [self add: @"Discard Pages" action: @selector(discardPages:) key: @"" to: m];
  [m addItem: [NSMenuItem separatorItem]];
  [self add: @"Move Page Up" action: @selector(movePageUp:) key: @"" to: m];
  [self add: @"Move Page Down" action: @selector(movePageDown:) key: @"" to: m];
  [self add: @"Delete Page" action: @selector(deletePage:) key: @"" to: m];
  [m addItem: [NSMenuItem separatorItem]];
  [self add: @"Install Text Recognition..." action: @selector(installTextRecognition:)
        key: @"" to: m];

  m = [self addMenu: @"View" to: main];
  [self add: @"Zoom In" action: @selector(zoomIn:) key: @"+" to: m];
  [self add: @"Zoom Out" action: @selector(zoomOut:) key: @"-" to: m];
  [self add: @"Zoom to Fit" action: @selector(zoomToFit:) key: @"0" to: m];
  [m addItem: [NSMenuItem separatorItem]];
  [self add: @"Select Document Automatically" action: @selector(autoSelect:)
        key: @"" to: m];
  [self add: @"Remove All Selections" action: @selector(removeAllSelections:)
        key: @"" to: m];

  m = [self addMenu: @"Window" to: main];
  [self add: @"Minimize" action: @selector(performMiniaturize:) key: @"m" to: m];
  [NSApp setWindowsMenu: m];

  [NSApp setMainMenu: main];
}

#pragma mark Launch and quit

- (void) applicationWillFinishLaunching: (NSNotification *)n
{
  [SCPreferences registerDefaults];
  [self setupMenu];
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  _chooser = [SCDeviceChooser new];
  [_chooser setDelegate: self];
  [self startScanning];
}

/*
 * A printer with a scanner connected by USB usually speaks IPP-over-USB;
 * sane-airscan reaches it only through ipp-usb, which is then offered,
 * or started when it is installed but not running
 */
- (void) deviceChooser: (SCDeviceChooser *)chooser didFindDevices: (NSArray *)devices
{
  NSArray *names = [SCIPPUSB connectedDeviceNames];
  NSString *what, *reason;
  BOOL installed = [SCIPPUSB programPath] != nil;

  if (_usbScanningOffered || [names count] == 0 || [SCIPPUSB isRunning])
    {
      return;
    }
  _usbScanningOffered = YES;
  what = [NSString stringWithFormat: @"USB scanning for %@",
                   [names componentsJoinedByString: @", "]];
  reason = [NSString stringWithFormat:
    @"%@ is connected by USB. Like most current printers with a scanner, it "
    @"scans over USB through IPP-over-USB, which needs the ipp-usb service.",
    [names componentsJoinedByString: @", "]];
  if (installed)
    {
      NSAlert *alert = [NSAlert new];

      [alert setMessageText: [NSString stringWithFormat: @"Start %@?", what]];
      [alert setInformativeText: [reason stringByAppendingString:
        @" It is installed but not running; starting it needs your password."]];
      [alert addButtonWithTitle: @"Start"];
      [alert addButtonWithTitle: @"Not Now"];
      if ([alert runModal] == NSAlertFirstButtonReturn)
        {
          [self startUSBScanning];
        }
      return;
    }
  [SCSoftwareInstaller offerPackages: [SCSoftwareInstaller usbScanningPackages]
                                what: what reason: reason
                          completion: ^(BOOL done) {
      if (done)
        {
          [self startUSBScanning];
        }
    }];
}

- (void) startUSBScanning
{
  [_chooser setBusy: YES message: @"Starting USB scanning..."];
  [SCIPPUSB startWithCompletion: ^(BOOL running) {
      [_chooser setBusy: NO message: running ? @"" :
        @"USB scanning could not be started."];
      if (running)
        {
          /* The printer now appears like a network scanner */
          [_chooser showAndSearch];
        }
    }];
}

/* SANE is installed only when Scanner is used; until then there is nothing to open */
- (BOOL) deviceChooserShouldSearch: (SCDeviceChooser *)chooser
{
  if (_saneReady)
    {
      return YES;
    }
  [self offerScannerSupport];
  return NO;
}

- (void) offerScannerSupport
{
  [_chooser showWindow: nil];
  [_chooser setBusy: NO message: @"Scanner support (SANE) is not installed yet."];
  [SCSoftwareInstaller offerPackages: [SCSoftwareInstaller scannerSupportPackages]
                                what: @"scanner support"
                              reason: @"Scanner talks to scanners through SANE, "
                                      @"which comes with drivers for most "
                                      @"scanners, connected by USB or over the "
                                      @"network."
                          completion: ^(BOOL installed) {
      if (installed)
        {
          [self startScanning];
        }
      else
        {
          [_chooser setBusy: NO message: @"Scanner support (SANE) is not "
                    @"installed. Choose Search Again to install it."];
        }
    }];
}

- (void) startScanning
{
  NSError *error = nil;
  SCDeviceInfo *last;

  if (![SCScanner initializeSANEWithError: &error])
    {
      if ([error code] == SCSaneNotInstalledError)
        {
          [self offerScannerSupport];
          return;
        }
      [[NSAlert alertWithError: error] runModal];
      [NSApp terminate: nil];
      return;
    }
  _saneReady = YES;
  [SCScanner setAuthenticationHandler:
    ^BOOL (NSString *resource, NSString **user, NSString **password) {
      return [SCPasswordPanel askForResource: resource user: user password: password];
    }];

  /* "Scanner -d airscan:w1:..." opens that device directly, like scanimage -d */
  _requestedDevice = [[NSUserDefaults standardUserDefaults] stringForKey: @"d"];
  _firstSearch = YES;
  if (_requestedDevice != nil)
    {
      SCDeviceInfo *d = [[SCDeviceInfo alloc] initWithName: _requestedDevice
                                                    vendor: @""
                                                     model: _requestedDevice
                                                      kind: @""];
      [_chooser showWindow: nil];
      [self deviceChooser: _chooser didChooseDevice: d];
      return;
    }
  last = [SCDeviceInfo deviceWithPropertyList:
            [[NSUserDefaults standardUserDefaults] dictionaryForKey: SCLastDeviceKey]];
  if (last != nil)
    {
      /* The chooser only appears when the last scanner cannot be opened */
      _openingLastDevice = YES;
      [self deviceChooser: _chooser didChooseDevice: last];
      return;
    }
  [_chooser showAndSearch];
}

/*
 * Gershwin quits apps when their last window closes. Here windows come and
 * go while a scanner opens (none at all while the last one reopens, the
 * chooser closing as the scan window appears), so the app decides itself:
 * it quits when the scan window is closed, see -scanWindowWillClose:.
 */
- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)app
{
  return NO;
}

- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication *)app
{
  if ([_scanWindow isScanning] || _opening)
    {
      /* The SANE handle cannot be closed under a running scan or open */
      NSBeep();
      return NSTerminateCancel;
    }
  if (_scanWindow != nil && ![_scanWindow mayCloseWithCollectedPages])
    {
      return NSTerminateCancel;
    }
  return NSTerminateNow;
}

- (void) applicationWillTerminate: (NSNotification *)n
{
  [_scanWindow saveDeviceSettings];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [_scanWindow stopPanelScanning];
  [[_scanWindow scanner] close];
  [SCScanner exitSANE];
  if ([SCScanner mustSkipExitHandlers])
    {
      _exit(0);
    }
}

#pragma mark Choosing a scanner

- (SCDeviceInfo *) deviceChooser: (SCDeviceChooser *)chooser
       deviceToOpenAutomaticallyFrom: (NSArray *)devices
{
  id saved = [[NSUserDefaults standardUserDefaults] objectForKey: SCLastDeviceKey];
  /* Earlier versions stored the bare device name */
  NSString *lastName = [saved isKindOfClass: [NSDictionary class]]
    ? [saved objectForKey: @"Name"] : saved;
  NSString *last = [lastName isKindOfClass: [NSString class]]
    ? SCPersistentDeviceIdentifier(lastName) : nil;
  BOOL first = _firstSearch;

  _firstSearch = NO;
  /* Only at launch; "Choose Scanner..." must let the user choose */
  if (!first)
    {
      return nil;
    }
  if ([devices count] == 1)
    {
      return [devices objectAtIndex: 0];
    }
  for (SCDeviceInfo *d in devices)
    {
      if ([[d persistentIdentifier] isEqualToString: last])
        {
          return d;
        }
    }
  return nil;
}

- (void) deviceChooser: (SCDeviceChooser *)chooser didChooseDevice: (SCDeviceInfo *)device
{
  if (_opening)
    {
      return;
    }
  if (_scanWindow != nil && ![[[[_scanWindow scanner] device] name]
                               isEqualToString: [device name]]
      && ![_scanWindow mayCloseWithCollectedPages])
    {
      return;
    }
  if (_scanWindow != nil && [[[[_scanWindow scanner] device] name]
                              isEqualToString: [device name]])
    {
      /* In this order: Gershwin quits an app the moment it has no window left */
      [_scanWindow showWindow: nil];
      [[chooser window] close];
      return;
    }
  _opening = YES;
  [chooser setBusy: YES message: [NSString stringWithFormat: @"Opening %@...",
                                           [device displayName]]];
  /* Closed first: a driver may refuse to open while the old handle is still open */
  [self closeScanWindow];
  [NSThread detachNewThreadSelector: @selector(openThread:) toTarget: self
                         withObject: device];
}

- (void) openThread: (SCDeviceInfo *)device
{
  @autoreleasepool
    {
      NSError *error = nil;
      SCScanner *scanner = [SCScanner scannerOpeningDevice: device error: &error];
      NSDictionary *result = scanner ? @{@"scanner": scanner}
        : @{@"error": error, @"device": [device name]};

      [self performSelectorOnMainThread: @selector(openFinished:)
                             withObject: result waitUntilDone: NO];
    }
}

- (void) openFinished: (NSDictionary *)result
{
  SCScanner *scanner = [result objectForKey: @"scanner"];

  _opening = NO;
  if (scanner == nil && _openingLastDevice)
    {
      /* Gone, renamed or busy: look for it, and let the user choose otherwise */
      _openingLastDevice = NO;
      [_chooser showAndSearch];
      return;
    }
  if (scanner == nil)
    {
      NSString *message = [[result objectForKey: @"error"] localizedDescription];
      NSString *name = [result objectForKey: @"device"];
      NSString *usb = nil;

      /* Network, virtual and camera devices do not depend on USB permissions */
      if (![name hasPrefix: @"airscan:"] && ![name hasPrefix: @"net:"]
          && ![name hasPrefix: @"escl:"] && ![name hasPrefix: @"test:"]
          && ![name hasPrefix: @"v4l:"])
        {
          usb = [SCPermissionCheck problemWithUSBAccess];
        }
      if (usb != nil)
        {
          message = [NSString stringWithFormat: @"%@. %@", message, usb];
        }
      [_chooser setBusy: NO message: message];
      [_chooser showWindow: nil];
      return;
    }
  _openingLastDevice = NO;
  [[NSUserDefaults standardUserDefaults] setObject: [[scanner device] propertyList]
                                            forKey: SCLastDeviceKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [_chooser setBusy: NO message: @""];
  _scanWindow = [[SCScanWindow alloc] initWithScanner: scanner];
  [[NSNotificationCenter defaultCenter]
    addObserver: self selector: @selector(scanWindowWillClose:)
           name: NSWindowWillCloseNotification object: [_scanWindow window]];
  /* In this order: Gershwin quits an app the moment it has no window left */
  [_scanWindow showWindow: nil];
  [[_chooser window] close];
  /* Deferred, so the alert comes up over the window that is now shown */
  [_scanWindow performSelector: @selector(offerTextRecognitionOnFirstLaunch)
                    withObject: nil afterDelay: 0.5];
}

- (void) closeScanWindow
{
  if (_scanWindow == nil)
    {
      return;
    }
  [_scanWindow saveDeviceSettings];
  [[NSNotificationCenter defaultCenter]
    removeObserver: self name: NSWindowWillCloseNotification
            object: [_scanWindow window]];
  [[_scanWindow window] close];
  [_scanWindow stopPanelScanning];
  [[_scanWindow scanner] close];
  _scanWindow = nil;
}

- (void) scanWindowWillClose: (NSNotification *)n
{
  /* The scan window is the application; without a scanner there is nothing to do */
  [NSApp terminate: nil];
}

- (void) chooseScanner: (id)sender
{
  if ([_scanWindow isScanning] || _opening)
    {
      NSBeep();
      return;
    }
  [_chooser showAndSearch];
}

- (void) showPreferences: (id)sender
{
  if (_preferences == nil)
    {
      _preferences = [SCPreferences new];
    }
  [_preferences showWindow: nil];
}

#pragma mark Scan actions, forwarded to the scan window

- (void) preview: (id)sender { [_scanWindow preview: sender]; }
- (void) scan: (id)sender { [_scanWindow scan: sender]; }
- (void) cancelScan: (id)sender { [_scanWindow cancelScan: sender]; }
- (void) savePages: (id)sender { [_scanWindow savePages: sender]; }
- (void) discardPages: (id)sender { [_scanWindow discardPages: sender]; }
- (void) deletePage: (id)sender { [_scanWindow deletePage: sender]; }
- (void) movePageUp: (id)sender { [_scanWindow movePageUp: sender]; }
- (void) movePageDown: (id)sender { [_scanWindow movePageDown: sender]; }
- (void) showSavedFile: (id)sender { [_scanWindow showSavedFile: sender]; }
- (void) installTextRecognition: (id)sender { [_scanWindow installTextRecognition: sender]; }
- (void) zoomIn: (id)sender { [_scanWindow zoomIn: sender]; }
- (void) zoomOut: (id)sender { [_scanWindow zoomOut: sender]; }
- (void) zoomToFit: (id)sender { [_scanWindow zoomToFit: sender]; }
- (void) autoSelect: (id)sender { [_scanWindow autoSelect: sender]; }
- (void) removeAllSelections: (id)sender { [_scanWindow removeAllSelections: sender]; }

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
  SEL a = [item action];

  if (a == @selector(chooseScanner:))
    {
      return ![_scanWindow isScanning] && !_opening;
    }
  if (a == @selector(showPreferences:))
    {
      return YES;
    }
  if (_scanWindow == nil)
    {
      return NO;
    }
  return [(id)_scanWindow validateMenuItem: item];
}

@end
