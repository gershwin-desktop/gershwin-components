/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundExtra.h"
#import "SoundBackendFactory.h"
#import "GSMenuExtraContext.h"
#import "MediaKeyController.h"
#import "JackSupervisor.h"


static const BOOL kShowTextInMenuBar = NO;
static const NSInteger kJackStatusTag = 4711;

@implementation SoundExtra
{
    BOOL _running;
    float _volume;
    BOOL _muted;
    BOOL _backendAvailable;
    GSMenuExtraContext *_context;
    id<SoundBackend> _backend;
    JackSupervisor *_jack;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)updateState
{
    float oldVolume = _volume;
    BOOL oldMuted = _muted;
    BOOL wasAvailable = _backendAvailable;
    _backendAvailable = [_backend isAvailable];
    if (!_backendAvailable) {
        _volume = 0.0f;
        _muted = NO;
        if (wasAvailable || oldVolume != _volume || oldMuted != _muted) {
            [_context invalidatePresentation];
        }
        return;
    }
    _volume = [_backend outputVolume];
    _muted = [_backend isOutputMuted];
    if (oldVolume != _volume || oldMuted != _muted) {
        [_context invalidatePresentation];
    }
}

- (NSString *)volumeLabel
{
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return [NSString stringWithFormat:@"Volume %d%%", pct];
}

#pragma mark - GSMenuExtra

// The JACK line exists only while UseJack is on.
- (void)addJackStatusItemTo:(NSMenu *)m
{
    NSString *title = [JackSupervisor menuTitleForStatus:[_jack statusDictionary]];
    if (title == nil) return;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    [item setTag:kJackStatusTag];
    [item setEnabled:NO];
    [m addItem:item];
}

- (NSMenu *)menu
{
    if (!_backendAvailable) {
        NSMenu *m = [[NSMenu alloc] initWithTitle:@"Sound"];
        NSMenuItem *na = [[NSMenuItem alloc] initWithTitle:@"Sound: Unavailable"
                                                    action:NULL
                                             keyEquivalent:@""];
        [na setEnabled:NO];
        [m addItem:na];
        [self addJackStatusItemTo:m];
        return m;
    }

    BOOL muted = _muted;
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Sound"];

    NSMenuItem *volItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Volume %d%%", pct]
                                                       action:NULL
                                                keyEquivalent:@""];
    [volItem setEnabled:NO];
    [m addItem:volItem];
    [self addJackStatusItemTo:m];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *muteItem = [[NSMenuItem alloc] initWithTitle:@"Mute"
                                                       action:@selector(toggleMute:)
                                                keyEquivalent:@""];
    [muteItem setTarget:self];
    [muteItem setState:muted ? NSOnState : NSOffState];
    [m addItem:muteItem];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"Volume Up"
                                                 action:@selector(volUp:)
                                          keyEquivalent:@""];
    [up setTarget:self];
    if (muted) [up setEnabled:NO];
    [m addItem:up];

    NSMenuItem *down = [[NSMenuItem alloc] initWithTitle:@"Volume Down"
                                                   action:@selector(volDown:)
                                            keyEquivalent:@""];
    [down setTarget:self];
    if (muted) [down setEnabled:NO];
    [m addItem:down];

    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences"
                                                    action:@selector(openSoundPrefs:)
                                             keyEquivalent:@""];
    [prefs setTarget:self];
    [m addItem:prefs];

    return m;
}

- (NSImage *)image
{
    NSString *name;
    if (_muted) {
        name = @"volume-muted";
    } else if (_volume < 0.33) {
        name = @"volume-low";
    } else if (_volume < 0.66) {
        name = @"volume-medium";
    } else {
        name = @"volume-high";
    }
    return [NSImage imageNamed:name];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    if (!_backendAvailable) return @"--";
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return [NSString stringWithFormat:@"%d%%", pct];
}

- (void)menuExtraDidLoad
{
    @try {
        _running = YES;
        _backend = SoundBackendCreateDefault();
        /* Menu runs for the whole session, so it is the one place that can
           keep jackd and its bridges going while the user has JACK on. */
        _jack = [[JackSupervisor alloc] init];
        [_jack start];
        [self updateState];
        /* The volume keys are handled by Menu itself, so they keep working
           when this extra is not shown; it only has to reflect the change. */
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(soundVolumeChanged:)
                                                     name:MediaKeySoundVolumeChangedNotification
                                                   object:nil];
    } @catch (NSException *e) {
        NSLog(@"SoundExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        [_jack stop];
        _jack = nil;
        DESTROY(_backend);
    }
}

- (void)soundVolumeChanged:(NSNotification *)notification
{
    (void)notification;
    [self updateState];
}

- (void)menuExtraWillOpenMenu
{
    _backendAvailable = [_backend isAvailable];
    if (_backendAvailable) {
        _volume = [_backend outputVolume];
        _muted = [_backend isOutputMuted];
    }
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    int pct = (int)(_volume * 100.0f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    BOOL muted = _muted;
    for (NSMenuItem *item in [submenu itemArray]) {
        NSString *title = [item title];
        if ([item tag] == kJackStatusTag) {
            NSString *jack = [JackSupervisor menuTitleForStatus:[_jack statusDictionary]];
            if (jack) [item setTitle:jack];
        } else if ([title isEqualToString:@"Volume Up"] || [title isEqualToString:@"Volume Down"]) {
            [item setEnabled:!muted];
        } else if ([title hasPrefix:@"Volume "]) {
            [item setTitle:[NSString stringWithFormat:@"Volume %d%%", pct]];
        } else if ([title isEqualToString:@"Mute"]) {
            [item setState:muted ? NSOnState : NSOffState];
        }
    }
}

- (void)menuExtraWillUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    /* Before the backend goes: ALSA applications must not be left on a
       ~/.asoundrc that points at a jackd being stopped. */
    [_jack stop];
    _jack = nil;
    DESTROY(_backend);
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    if (!_running) return;
    (void)timer;
    BOOL wasAvailable = _backendAvailable;
    _backendAvailable = [_backend isAvailable];
    if (!_backendAvailable) {
        _volume = 0.0f;
        if (wasAvailable) {
            [_context invalidatePresentation];
        }
        return;
    }
    float newVolume = [_backend outputVolume];
    if (newVolume != _volume) {
        _volume = newVolume;
        [_context invalidatePresentation];
    }
}

#pragma mark - Actions

- (void)toggleMute:(id)sender
{
    (void)sender;
    [_backend setOutputMuted:![_backend isOutputMuted]];
    [self updateState];
}

- (void)volUp:(id)sender
{
    (void)sender;
    float vol = [_backend outputVolume];
    vol += (1.0f - 0.01f) / 7.0f;
    if (vol > 1.0f) vol = 1.0f;
    [_backend setOutputVolume:vol];
    [self updateState];
}

- (void)volDown:(id)sender
{
    (void)sender;
    float vol = [_backend outputVolume];
    vol -= (1.0f - 0.01f) / 7.0f;
    if (vol < 0.01f) vol = 0.01f;
    [_backend setOutputVolume:vol];
    [self updateState];
}

- (void)openSoundPrefs:(id)sender
{
    (void)sender;
    NSString *prefPaneID = @"Sound";
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
