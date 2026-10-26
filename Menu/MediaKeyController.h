/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class X11ShortcutManager;

/* Posted on the main thread after a key changed the output volume or mute
 * state, so the Sound menu extra can refresh. */
extern NSString * const MediaKeySoundVolumeChangedNotification;
/* Posted on the main thread after a key changed the display brightness. */
extern NSString * const MediaKeyBrightnessChangedNotification;

/* Handles the volume, mute, microphone mute, brightness and radio keys for
 * the whole desktop.  They are grabbed as X keysyms, which every supported
 * operating system delivers, and handled here rather than in the menu
 * extras so they keep working when an extra is not shown. */
@interface MediaKeyController : NSObject

- (instancetype)initWithShortcutManager:(X11ShortcutManager *)manager;

@end
