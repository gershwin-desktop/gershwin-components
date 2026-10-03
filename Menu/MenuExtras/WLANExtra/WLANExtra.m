/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANExtra.h"
#import "NMBackend.h"
#import "BSDBackend.h"
#import "NetworkBackend.h"
#import "CaptivePortalDetector.h"
#import "GSMenuExtraContext.h"
#import "WLANMenuListPolicy.h"

#import "AppearanceMetrics.h"
#include <sys/utsname.h>
#include <string.h>

@interface WLANExtra (Private)
- (NSString *)_activeWLANSsidFromNMCLI;
@end
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>
#endif

static const BOOL kShowTextInMenuBar = NO;

/* The manager ticks every extra every 2 seconds; a WLAN refresh costs two
   blocking nmcli calls (radio state plus a cached scan), so only ask for one
   every fifth tick (10 s).  Opening the menu always refreshes immediately. */
static const int kWLANRefreshTicks = 5;

static BOOL ShouldUseBSDNetworkBackend(void)
{
#if defined(__OpenBSD__) || defined(__NetBSD__)
    return YES;
#elif defined(__FreeBSD__) || defined(__DragonFly__)
    BOOL isBSD = NO;
    {
        char ostype[64] = {0};
        size_t len = sizeof(ostype) - 1;
        if (sysctlbyname("kern.ostype", ostype, &len, NULL, 0) == 0) {
            if (strcmp(ostype, "FreeBSD") == 0 ||
                strcmp(ostype, "DragonFly") == 0) {
                isBSD = YES;
            }
        }
    }
    if (!isBSD) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm isExecutableFileAtPath:@"/usr/sbin/sysrc"]) {
            isBSD = YES;
        }
    }
    if (!isBSD) {
        struct utsname uts;
        if (uname(&uts) == 0 &&
            (strcmp(uts.sysname, "FreeBSD") == 0 ||
             strcmp(uts.sysname, "DragonFly") == 0)) {
            isBSD = YES;
        }
    }
    return isBSD;
#else
    return NO;
#endif
}

static id<NetworkBackend> CreateNetworkBackend(void)
{
    if (ShouldUseBSDNetworkBackend()) {
        return [[BSDBackend alloc] init];
    }
    return [[NMBackend alloc] init];
}

@interface WLANExtra ()
@end

@implementation WLANExtra
{
    id<NetworkBackend> _backend;
    BOOL _backendAvailable;
    BOOL _wlanEnabled;
    WLAN *_connectedWLAN;
    int _signalStrength;
    NSArray<WLAN *> *_networkList;
    GSMenuExtraContext *_context;
    NSString *_previousConnectedSSID;
    NSString *_captivePortalAlertShownSSID;
    BOOL _hasInternetAccess;
    NSPanel *_captivePortalPanel;
    NSString *_captivePortalRedirectURL;
    BOOL _running;
    int _ticksSinceRefresh;
    BOOL _refreshInFlight;
    BOOL _menuOpenPending;
}

- (NSString *)_activeWLANSsidFromNMCLI
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/nmcli"];
    [task setArguments:@[@"-t", @"-f", @"NAME,TYPE,DEVICE", @"connection", @"show", @"--active"]];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        NSLog(@"WLANExtra: nmcli failed: %@", e);
        return nil;
    }
    /* Read before wait: a child that fills the OS pipe buffer blocks in
     * write() and never exits, so waiting first would deadlock. */
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!output) return nil;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSArray *fields = [line componentsSeparatedByString:@":"];
        if ([fields count] >= 2 && [[fields objectAtIndex:1] isEqualToString:@"802-11-wireless"]) {
            NSLog(@"WLANExtra: nmcli live SSID = '%@'", [fields objectAtIndex:0]);
            return [fields objectAtIndex:0];
        }
    }
    return nil;
}

static NSString *findTool(NSString *name)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleDir = [[NSBundle mainBundle] resourcePath];
    NSString *candidate = [bundleDir stringByAppendingPathComponent:name];
    if ([fm isExecutableFileAtPath:candidate]) return candidate;
    candidate = [[NSBundle mainBundle] pathForAuxiliaryExecutable:name];
    if ([fm isExecutableFileAtPath:candidate]) return candidate;
    NSArray *dirs = @[@"/usr/local/bin", @"/usr/bin", @"/bin",
                       @"/usr/local/sbin", @"/usr/sbin", @"/sbin"];
    for (NSString *dir in dirs) {
        candidate = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)updateState
{
    if (!_running) return;
    NSString *oldIcon = [self iconName];

    _backendAvailable = [_backend isAvailable];
    if (!_backendAvailable) {
        _wlanEnabled = NO;
        _connectedWLAN = nil;
        _signalStrength = 0;
        _networkList = @[];
        [self invalidateIfIconChangedFrom:oldIcon];
        return;
    }

    _wlanEnabled = [_backend isWLANEnabled];
    if (!_wlanEnabled) {
        _connectedWLAN = nil;
        _signalStrength = 0;
        _networkList = @[];
    } else {
        _connectedWLAN = [_backend connectedWLAN];
        _signalStrength = _connectedWLAN ? [_connectedWLAN signalStrength] : 0;
        /* A scan that comes back empty (common right after connecting - see
           WLANMenuListPolicy) must not erase whatever the last scan found. */
        _networkList = [WLANMenuListPolicy networkListAfterScan:[_backend scanForWLANs]
                                                       cachedList:_networkList
                                                        connected:(_connectedWLAN != nil)];
    }

    [self invalidateIfIconChangedFrom:oldIcon];

    // Captive portal / internet connectivity check on WLAN SSID change
    NSString *currentSSID = [_connectedWLAN ssid];
    if (currentSSID && ![currentSSID isEqualToString:_previousConnectedSSID]) {
        _previousConnectedSSID = currentSSID;
        _captivePortalAlertShownSSID = nil;
        _hasInternetAccess = NO;
        [_context invalidatePresentation];
        [CaptivePortalDetector checkForCaptivePortalWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
            _hasInternetAccess = !isCaptive;
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(deferredInvalidatePresentation)
                                                       object:nil];
            [self performSelector:@selector(deferredInvalidatePresentation)
                     withObject:nil
                     afterDelay:0];
            if (isCaptive && redirectURL
                && ![_captivePortalAlertShownSSID isEqualToString:currentSSID]) {
                _captivePortalAlertShownSSID = currentSSID;
                [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                         selector:@selector(showCaptivePortalAlert:)
                                                           object:nil];
                [self performSelector:@selector(showCaptivePortalAlert:)
                         withObject:redirectURL
                         afterDelay:0];
            }
        }];
    } else if (!currentSSID) {
        _previousConnectedSSID = nil;
    }
}

#pragma mark - Actions

- (void)turnWLANOn:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: turnWLANOn sender=%@ backend=%@", sender, _backend);
    [_backend setWLANEnabled:YES];
    [self updateState];
}

- (void)turnWLANOff:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: turnWLANOff sender=%@ backend=%@", sender, _backend);
    [_backend setWLANEnabled:NO];
    [self updateState];
}

- (void)disconnectNetwork:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: disconnectNetwork sender=%@ backend=%@", sender, _backend);
    [_backend disconnectFromWLAN];
    [self updateState];
}

- (NSString *)runPasswordPanelForSSID:(NSString *)ssid
{
    NSString *toolPath = findTool(@"wlanauth");
    if (!toolPath) return nil;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:toolPath];
    [task setArguments:@[ssid]];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return nil;
    }
    /* Read before wait: a child that fills the OS pipe buffer blocks in
     * write() and never exits, so waiting first would deadlock. */
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if ([task terminationStatus] != 0) return nil;
    NSString *password = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
    password = [password stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ([password length] > 0) ? password : nil;
}

- (void)connectToNetwork:(id)sender
{
    NSString *ssid = [sender representedObject];
    NSString *security = [sender toolTip];
    if ([ssid length] == 0) return;

    WLAN *target = nil;
    for (WLAN *net in _networkList) {
        if ([[net ssid] isEqualToString:ssid]) {
            target = net;
            break;
        }
    }
    if (!target) return;

    /* The password helper (wlanauth) blocks until the user answers its dialog,
       and nmcli connect can take seconds.  Running any of that on the main
       thread froze the entire menu bar for the duration.  Do it all on a
       background queue; the state refresh is marshalled back to the main
       thread. */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* A block queued on a background queue runs on a thread of the
           dispatch library's own, and such a thread has no autorelease pool:
           without one here, everything autoreleased while doing this work is
           held until the process ends. */
        @autoreleasepool {
            NSString *password = nil;
            if ([security length] > 0) {
                password = [self runPasswordPanelForSSID:ssid];
                if (!password) return;
            }

            WLAN *connectTarget = target;
            [_backend connectToWLAN:connectTarget withPassword:password];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateState];
            });
        }
    });
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    BOOL wlanOn = _wlanEnabled;
    /* Renders the last known state only - no scan here. Scanning is a
       real NSTask exec (nmcli/ifconfig) that can take a second or more,
       and this method runs on the main thread while the menu bar is about
       to display. The periodic refresh keeps this state at most one
       interval old; the refresh -menuExtraWillOpenMenu starts updates the
       icon when it lands and the list on the next open. */
    NSArray *nets = _networkList ?: @[];
    WLAN *connected = _connectedWLAN;
    int signal = _signalStrength;
    NSString *connectedSSID = [connected ssid];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"WLAN"];

    if (!_backendAvailable) {
        NSMenuItem *na = [[NSMenuItem alloc] initWithTitle:@"WLAN: Unavailable"
                                                     action:NULL
                                              keyEquivalent:@""];
        [na setEnabled:NO];
        [m addItem:na];
        return m;
    }

    if (!wlanOn) {
        NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"WLAN: Off"
                                                     action:NULL
                                              keyEquivalent:@""];
        [off setEnabled:NO];
        [m addItem:off];
        [m addItem:[NSMenuItem separatorItem]];
        NSMenuItem *on = [[NSMenuItem alloc] initWithTitle:@"Turn WLAN On"
                                                    action:@selector(turnWLANOn:)
                                             keyEquivalent:@""];
        [on setTarget:self];
        [m addItem:on];
        return m;
    }

    if (connectedSSID) {
        NSString *label;
        if (_hasInternetAccess) {
            label = [NSString stringWithFormat:@"Connected: %@", connectedSSID];
        } else {
            label = [NSString stringWithFormat:@"Connected: %@ (No Internet)", connectedSSID];
        }
        NSMenuItem *conn = [[NSMenuItem alloc] initWithTitle:label
                                                       action:NULL
                                                keyEquivalent:@""];
        [conn setEnabled:NO];
        [m addItem:conn];

        NSString *sigLabel = [NSString stringWithFormat:@"Signal: %d dBm", signal];
        NSMenuItem *sig = [[NSMenuItem alloc] initWithTitle:sigLabel
                                                     action:NULL
                                              keyEquivalent:@""];
        [sig setEnabled:NO];
        [m addItem:sig];

        [m addItem:[NSMenuItem separatorItem]];

        NSMenuItem *disconn = [[NSMenuItem alloc] initWithTitle:@"Disconnect"
                                                         action:@selector(disconnectNetwork:)
                                                  keyEquivalent:@""];
        [disconn setTarget:self];
        [m addItem:disconn];
    } else {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"Not Connected"
                                                      action:NULL
                                               keyEquivalent:@""];
        [none setEnabled:NO];
        [m addItem:none];
    }

    [m addItem:[NSMenuItem separatorItem]];

    int count = 0;
    for (WLAN *net in nets) {
        if (count++ >= 20) break;
        NSString *ssid = [net ssid];
        if ([ssid length] == 0) continue;

        WLANSecurityType secType = [net security];
        BOOL isSecure = (secType != WLANSecurityNone);
        NSString *iconName = [[self class] iconNameForSignalStrength:[net signalStrength]];
        if (isSecure) {
            iconName = [iconName stringByAppendingString:@"-locked"];
        }

        NSMenuItem *netItem = [[NSMenuItem alloc] initWithTitle:ssid
                                                         action:@selector(connectToNetwork:)
                                                  keyEquivalent:@""];
        [netItem setImage:[NSImage imageNamed:iconName]];
        [netItem setTarget:self];
        [netItem setRepresentedObject:ssid];
        [netItem setToolTip:isSecure ? @"WPA" : @""];
        if ([ssid isEqualToString:connectedSSID]) {
            [netItem setState:NSOnState];
        }

        [m addItem:netItem];
    }

    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"Turn WLAN Off"
                                                 action:@selector(turnWLANOff:)
                                          keyEquivalent:@""];
    [off setTarget:self];
    [m addItem:off];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences"
                                                    action:@selector(openNetworkPrefs:)
                                             keyEquivalent:@""];
    [prefs setTarget:self];
    [m addItem:prefs];

    return m;
}

/* The menu bar icon and the network list share these signal levels, so a
   network looks the same in both. */
+ (NSString *)iconNameForSignalStrength:(int)dBm
{
    if (dBm >= -50) return @"wlan";
    if (dBm >= -60) return @"wlan-good";
    if (dBm >= -70) return @"wlan-ok";
    return @"wlan-weak";
}

- (NSImage *)image
{
    NSString *name = [self iconName];
    return name ? [NSImage imageNamed:name] : nil;
}

/* What the menu bar draws, decided from one place.  Split out from -image so
   that a refresh can compare the icon it would draw now with the one it drew
   before and only then ask the manager to repaint. */
- (NSString *)iconName
{
    if (!_backendAvailable) return @"wlan-disabled";
    if (!_wlanEnabled) return @"wlan-off";
    /* Radio on but not associated: the greyed-out arcs, never a signal level
       borrowed from some other network. */
    if (!_connectedWLAN) return @"wlan-disabled";
    /* Connected but the strength unknown (the live SSID lookup only knows the
       SSID).  Real strength is negative dBm, so 0 means "not measured" and
       the full arcs stand for "connected". */
    if (_signalStrength >= 0) return @"wlan";
    return [[self class] iconNameForSignalStrength:_signalStrength];
}

- (void)invalidateIfIconChangedFrom:(NSString *)oldIcon
{
    NSString *newIcon = [self iconName];
    if (oldIcon == newIcon) return;
    if (oldIcon && newIcon && [oldIcon isEqualToString:newIcon]) return;
    [_context invalidatePresentation];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    if (!_backendAvailable) return @"--";
    if (!_wlanEnabled) return @"Off";
    if (_connectedWLAN) return [NSString stringWithFormat:@"%d", _signalStrength];
    return @"--";
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        _backend = CreateNetworkBackend();
        [self updateState];
    } @catch (NSException *e) {
        NSLog(@"WLANExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _backend = nil;
        _connectedWLAN = nil;
        _networkList = nil;
        _context = nil;
        _previousConnectedSSID = nil;
        _captivePortalAlertShownSSID = nil;
        _captivePortalPanel = nil;
        _captivePortalRedirectURL = nil;
    }
}

- (void)menuExtraWillOpenMenu
{
    @try {
        /* This open refreshes now, so the next periodic refresh is a full
           interval away rather than possibly a second scan right after. */
        _ticksSinceRefresh = 0;
        [self refreshAsyncForMenuOpen:YES];
    } @catch (NSException *e) {
        NSLog(@"WLANExtra: exception in menuExtraWillOpenMenu: %@", e);
    }
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    NSString *connectedSSID = [_connectedWLAN ssid];
    for (NSMenuItem *item in [submenu itemArray]) {
        NSString *ssid = [item representedObject];
        if ([ssid isKindOfClass:[NSString class]]) {
            [item setState:[ssid isEqualToString:connectedSSID] ? NSOnState : NSOffState];
        }
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
    _backend = nil;
}

- (void)tick
{
    @try {
        if (!_running) return;
        if (++_ticksSinceRefresh < kWLANRefreshTicks) return;
        _ticksSinceRefresh = 0;
        [self refreshAsyncForMenuOpen:NO];
    } @catch (NSException *e) {
        NSLog(@"WLANExtra: exception in tick: %@", e);
    }
}

/* The one refresh path, for the periodic tick and for opening the menu.
   Radio state, scan and the nmcli SSID fallback are all process execs that
   block for as long as they like, and doing any of them on the main thread
   stalls the whole menu bar.  A refresh already under way absorbs further
   requests instead of starting a second scan; a menu opened meanwhile only
   marks that refresh's result as one the user is waiting for. */
- (void)refreshAsyncForMenuOpen:(BOOL)forMenuOpen
{
    if (!_running) return;
    if (_refreshInFlight) {
        if (forMenuOpen) _menuOpenPending = YES;
        return;
    }
    /* Captured here, on the main thread that owns it: the block below must
       not read the ivar again, because menuExtraWillUnload can nil it while
       the scan is still running. */
    id<NetworkBackend> backend = _backend;
    if (!backend) return;
    _refreshInFlight = YES;
    _menuOpenPending = forMenuOpen;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* A block on a dispatch queue has no autorelease pool of its own;
           without one everything autoreleased here lives until exit. */
        @autoreleasepool {
            BOOL available = NO;
            BOOL enabled = NO;
            NSArray *nets = nil;
            WLAN *connected = nil;
            @try {
                available = [backend isAvailable];
                enabled = available ? [backend isWLANEnabled] : NO;
                if (enabled) {
                    nets = [backend scanForWLANs];
                    /* The scan itself says which network is in use.  The
                       backend's connectedWLAN reads a cache that this call
                       only queues up for the main thread, so here it is
                       still the previous scan's answer - and a cache-only
                       answer never shows the signal moving. */
                    for (WLAN *net in nets) {
                        if ([net isConnected]) { connected = net; break; }
                    }
                    if (!connected) connected = [backend connectedWLAN];
                    /* Both miss an association NetworkManager already has
                       when the scan came back empty (see WLANMenuListPolicy)
                       or the backend just started.  The live query bypasses
                       the privileged path that may hang on sudo/askpass; it
                       is one more exec, so only for a menu being opened. */
                    if (!connected && forMenuOpen) {
                        NSString *liveSSID = [self _activeWLANSsidFromNMCLI];
                        if (liveSSID) {
                            WLAN *live = [[WLAN alloc] init];
                            [live setSsid:liveSSID];
                            [live setIsConnected:YES];
                            [live setSignalStrength:0];
                            connected = live;
                        }
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"WLANExtra: exception in background refresh: %@", e);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishRefresh];
                });
                return;
            }
            int signal = connected ? [connected signalStrength] : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self commitRefreshWithAvailable:available
                                         enabled:enabled
                                            nets:nets
                                       connected:connected
                                          signal:signal];
            });
        }
    });
}

/* Returns whether a menu open was waiting on the refresh that just ended. */
- (BOOL)finishRefresh
{
    BOOL forMenuOpen = _menuOpenPending;
    _refreshInFlight = NO;
    _menuOpenPending = NO;
    return forMenuOpen;
}

/* Runs on the main thread, which owns every ivar. */
- (void)commitRefreshWithAvailable:(BOOL)available
                           enabled:(BOOL)enabled
                              nets:(NSArray *)nets
                         connected:(WLAN *)connected
                            signal:(int)signal
{
    BOOL forMenuOpen = [self finishRefresh];
    if (!_running) return;
    NSString *oldIcon = [self iconName];

    _backendAvailable = available;
    _wlanEnabled = enabled;
    if (!available || !enabled) {
        _networkList = @[];
        _connectedWLAN = nil;
        _signalStrength = 0;
    } else {
        _networkList = [WLANMenuListPolicy networkListAfterScan:nets
                                                     cachedList:_networkList
                                                      connected:(connected != nil)];
        /* An empty scan with no connection is a query that failed, not
           proof that the network went away; keep what we already know. */
        if ([nets count] > 0 || connected) {
            _connectedWLAN = connected;
            _signalStrength = signal;
        }
    }

    [self invalidateIfIconChangedFrom:oldIcon];

    // Re-check internet / captive portal status when the menu was opened.
    // Force-check bypasses the 60s rate limiter - the user explicitly
    // asked for fresh data by opening the menu.
    NSString *menuOpenSSID = [_connectedWLAN ssid];
    if (forMenuOpen && menuOpenSSID) {
        _hasInternetAccess = NO;
        [CaptivePortalDetector checkForCaptivePortalForceWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
            self->_hasInternetAccess = !isCaptive;
            if (isCaptive && redirectURL
                && ![self->_captivePortalAlertShownSSID isEqualToString:menuOpenSSID]) {
                self->_captivePortalAlertShownSSID = menuOpenSSID;
                [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                         selector:@selector(showCaptivePortalAlert:)
                                                           object:nil];
                [self performSelector:@selector(showCaptivePortalAlert:)
                         withObject:redirectURL
                         afterDelay:0];
            }
        }];
    }
}

#pragma mark - Captive Portal

- (void)deferredInvalidatePresentation
{
    [_context invalidatePresentation];
}

- (void)captivePortalOpenURL:(NSString *)url
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/env"];
    [task setArguments:@[@"open", url]];
    [task launch];
}
- (void)showCaptivePortalAlert:(NSString *)redirectURL
{
    if (!redirectURL || [redirectURL length] == 0) return;

    NSDebugLLog(@"gwcomp", @"[WLANExtra] Captive portal detected, redirect to: %@", redirectURL);

    /*
     * NSAlert dialog disabled because both -runModal and
     * -beginSheetModalForWindow: (which calls runModalForWindow:
     * internally) block the X11 event loop in GNUstep, making the
     * entire system unresponsive.  A custom non-modal panel with the
     * gershwin-eau-theme style (AppearanceMetrics.h) should be used
     * here instead.
     *
     * For now we just open the browser directly.
     *
    // Build a non-modal floating panel to avoid blocking the X11 event loop
    // that runModal / beginSheet (both call runModalForWindow: internally) cause.
    CGFloat panelW = 460;
    CGFloat panelH = 150;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, panelW, panelH)
                                                styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [panel setTitle:@""];
    [panel setFloatingPanel:YES];
    [panel setReleasedWhenClosed:NO];

    NSImage *icon = [NSImage imageNamed:NSImageNameInfo];
    CGFloat iconSize = 32;
    CGFloat iconX = 18;
    CGFloat iconY = panelH - iconSize - 18;
    if (icon) {
        [icon setSize:NSMakeSize(iconSize, iconSize)];
        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(iconX, iconY, iconSize, iconSize)];
        [iconView setImage:icon];
        [[panel contentView] addSubview:iconView];
    }

    CGFloat labelX = iconX + iconSize + 12;
    CGFloat labelW = panelW - labelX - 18;

    NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, iconY, labelW, 20)];
    [titleField setStringValue:@"Captive Portal Detected"];
    [titleField setEditable:NO];
    [titleField setSelectable:NO];
    [titleField setBordered:NO];
    [titleField setDrawsBackground:NO];
    [titleField setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
    [[panel contentView] addSubview:titleField];

    NSTextField *msgField = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, 42, labelW, 72)];
    [msgField setStringValue:[NSString stringWithFormat:
        @"Login page: %@\n\n"
        @"The WLAN network requires you to sign in before accessing the internet.\n"
        @"Would you like to open the login page in your browser?", redirectURL]];
    [msgField setEditable:NO];
    [msgField setSelectable:YES];
    [msgField setBordered:NO];
    [msgField setDrawsBackground:NO];
    [msgField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [[panel contentView] addSubview:msgField];


    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(panelW - 180, 12, 80, 24)];
    [cancelBtn setTitle:@"Cancel"];
    [cancelBtn setTarget:self];
    [cancelBtn setAction:@selector(_captivePortalCancel:)];

    NSButton *openBtn = [[NSButton alloc] initWithFrame:NSMakeRect(panelW - 90, 12, 80, 24)];
    [openBtn setTitle:@"Open"];
    [openBtn setTarget:self];
    [openBtn setAction:@selector(_captivePortalOpen:)];

    [[panel contentView] addSubview:cancelBtn];
    [[panel contentView] addSubview:openBtn];

    _captivePortalPanel = panel;
    _captivePortalRedirectURL = redirectURL;

    [panel center];
    [panel makeKeyAndOrderFront:self];
     */

    // Just open the browser directly - no modal dialog needed.
    [self captivePortalOpenURL:redirectURL];
}

- (void)_captivePortalCancel:(id)sender
{
    (void)sender;
    if (_captivePortalPanel) {
        [_captivePortalPanel close];
        _captivePortalPanel = nil;
    }
    _captivePortalRedirectURL = nil;
}

- (void)_captivePortalOpen:(id)sender
{
    (void)sender;
    NSString *url = _captivePortalRedirectURL;
    if (url) {
        [self captivePortalOpenURL:url];
    }
    if (_captivePortalPanel) {
        [_captivePortalPanel close];
        _captivePortalPanel = nil;
    }
    _captivePortalRedirectURL = nil;
}

- (void)openNetworkPrefs:(id)sender
{
    (void)sender;
    NSString *prefPaneID = @"Network";
    NSString *appPath = [[NSWorkspace sharedWorkspace] fullPathForApplication:@"SystemPreferences"];
    if (!appPath) {
        appPath = @"/Developer/Library/Sources/gershwin-systempreferences/SystemPreferences/SystemPreferences.app";
    }
    NSString *execPath = nil;
    if (appPath) {
        execPath = [appPath stringByAppendingPathComponent:@"SystemPreferences"];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:execPath]) {
            execPath = [[NSBundle bundleWithPath:appPath] executablePath];
        }
    }
    if (execPath) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:execPath];
        [task setArguments:@[prefPaneID]];
        @try {
            [task launch];
            return;
        } @catch (NSException *e) {
        }
    }
    /* launchApplication: connects to the app via DO (blocking).  Keep it off
       the main thread so the menu never freezes during the launch. */
    [NSThread detachNewThreadWithBlock: ^{
        [[NSWorkspace sharedWorkspace] launchApplication:@"SystemPreferences"];
    }];
}

@end
