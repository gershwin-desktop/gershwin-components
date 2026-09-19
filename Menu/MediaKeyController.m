/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MediaKeyController.h"
#import "X11ShortcutManager.h"
#import "BacklightBackend.h"
#import "SoundBackendFactory.h"
#import "WLANBackend.h"

#import <X11/XF86keysym.h>

NSString * const MediaKeySoundVolumeChangedNotification = @"SoundVolumeChanged";
NSString * const MediaKeyBrightnessChangedNotification = @"BrightnessChanged";

/* Sixteen presses from silence to full volume and from dark to full
   brightness, fine enough to find a comfortable level. */
static const float kMediaKeyVolumeStep = 1.0f / 16.0f;
static const int kMediaKeyBrightnessSteps = 16;

@implementation MediaKeyController
{
    /* The sound backend shells out to mixer tools and the backends are not
       thread safe, so all hardware access runs one at a time off the main
       thread; the menu bar must not freeze while a key is handled. */
    NSOperationQueue *_hardwareQueue;
    id<SoundBackend> _soundBackend;
    id<BacklightBackend> _backlightBackend;
    WLANBackend *_wlanBackend;
}

- (instancetype)initWithShortcutManager:(X11ShortcutManager *)manager
{
    self = [super init];
    if (self) {
        _hardwareQueue = [[NSOperationQueue alloc] init];
        [_hardwareQueue setMaxConcurrentOperationCount:1];
        [_hardwareQueue addOperationWithBlock:^{
            /* Probing the sound devices takes a while; the keys only need
               the backends once they are pressed. */
            self->_soundBackend = SoundBackendCreateDefault();
            self->_backlightBackend = BacklightBackendCreateDefault();
        }];

        [manager registerXF86Key:XF86XK_AudioRaiseVolume target:self action:@selector(volumeUp)];
        [manager registerXF86Key:XF86XK_AudioLowerVolume target:self action:@selector(volumeDown)];
        [manager registerXF86Key:XF86XK_AudioMute target:self action:@selector(toggleMute)];
        [manager registerXF86Key:XF86XK_AudioMicMute target:self action:@selector(toggleMicrophoneMute)];
        [manager registerXF86Key:XF86XK_MonBrightnessUp target:self action:@selector(brightnessUp)];
        [manager registerXF86Key:XF86XK_MonBrightnessDown target:self action:@selector(brightnessDown)];
#ifndef __linux__
        /* On Linux the kernel's rfkill input handler already switches the
           radios on these keys; toggling here as well would undo it. */
        _wlanBackend = [[WLANBackend alloc] init];
        [manager registerXF86Key:XF86XK_WLAN target:self action:@selector(toggleRadios)];
        [manager registerXF86Key:XF86XK_RFKill target:self action:@selector(toggleRadios)];
#endif
    }
    return self;
}

/* The menu extras observe these on the main thread, where they draw. */
- (void)postOnMainThread:(NSString *)name
{
    [self performSelectorOnMainThread:@selector(postNotificationNamed:)
                           withObject:name
                        waitUntilDone:NO];
}

- (void)postNotificationNamed:(NSString *)name
{
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
}

#pragma mark - Sound

- (void)changeVolumeBy:(float)delta
{
    [_hardwareQueue addOperationWithBlock:^{
        id<SoundBackend> backend = self->_soundBackend;
        if (backend == nil) {
            return;
        }
        /* Changing the volume of a muted output would be inaudible, so the
           keys unmute it first. */
        if ([backend isOutputMuted]) {
            [backend setOutputMuted:NO];
        }
        /* The mixer stores fewer levels than it reports, so it hands back a
           slightly different volume than was set; snapping to the key's
           grid keeps up and down symmetric instead of drifting. */
        float steps = roundf(([backend outputVolume] + delta) / kMediaKeyVolumeStep);
        float volume = MAX(0.0f, MIN(steps * kMediaKeyVolumeStep, 1.0f));
        [backend setOutputVolume:volume];
        [self postOnMainThread:MediaKeySoundVolumeChangedNotification];
    }];
}

- (void)volumeUp
{
    [self changeVolumeBy:kMediaKeyVolumeStep];
}

- (void)volumeDown
{
    [self changeVolumeBy:-kMediaKeyVolumeStep];
}

- (void)toggleMute
{
    [_hardwareQueue addOperationWithBlock:^{
        id<SoundBackend> backend = self->_soundBackend;
        if (backend == nil) {
            return;
        }
        [backend setOutputMuted:![backend isOutputMuted]];
        [self postOnMainThread:MediaKeySoundVolumeChangedNotification];
    }];
}

/* The microphone mute LED follows the capture switch in the kernel, so
   toggling the switch is all it takes to keep the LED in sync. */
- (void)toggleMicrophoneMute
{
    [_hardwareQueue addOperationWithBlock:^{
        id<SoundBackend> backend = self->_soundBackend;
        if (backend == nil) {
            return;
        }
        [backend setInputMuted:![backend isInputMuted]];
    }];
}

#pragma mark - Brightness

- (void)changeBrightnessBySteps:(int)steps
{
    [_hardwareQueue addOperationWithBlock:^{
        id<BacklightBackend> backend = self->_backlightBackend;
        if (backend == nil) {
            return;
        }
        int maximum = [backend maximum];
        int step = MAX(maximum / kMediaKeyBrightnessSteps, 1);
        /* A completely dark panel looks like a dead screen; stay at the
           lowest visible level instead. */
        int lowest = MAX(maximum / 100, 1);
        int value = MAX(lowest, MIN([backend current] + steps * step, maximum));
        [backend set:value];
        [self postOnMainThread:MediaKeyBrightnessChangedNotification];
    }];
}

- (void)brightnessUp
{
    [self changeBrightnessBySteps:1];
}

- (void)brightnessDown
{
    [self changeBrightnessBySteps:-1];
}

#pragma mark - Radios

- (void)toggleRadios
{
    WLANBackend *backend = _wlanBackend;
    [_hardwareQueue addOperationWithBlock:^{
        if (![backend isAvailable]) {
            return;
        }
        [backend setWLANEnabled:![backend isWLANEnabled]];
    }];
}

@end
