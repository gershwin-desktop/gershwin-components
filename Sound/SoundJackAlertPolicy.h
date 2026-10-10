/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Which PCM the alert sound plays through while JACK is in use, and when the
 * Sound pane may play it after the user clicked an output device.  Decisions
 * only, on dictionaries, so they are testable without a sound server.
 * Foundation only.
 */

#import <Foundation/Foundation.h>

typedef enum {
    /* JACK is not in effect: play on the selected card as without JACK */
    SoundJackAlertPlayOnCard,
    /* the routing to the selected device has not moved yet */
    SoundJackAlertKeepWaiting,
    /* routing confirmed: play through the default PCM */
    SoundJackAlertPlayDefault,
    /* not confirmed in time: play through the default PCM anyway */
    SoundJackAlertPlayDefaultUnconfirmed
} SoundJackAlertAction;

@interface SoundJackAlertPolicy : NSObject

/* "default" while UseJack is set and the server runs (the cards belong to
   jackd then and the default PCM is the jack plugin), else cardDevice. */
+ (NSString *)playbackDeviceForSettings:(NSDictionary *)settings
                                 status:(NSDictionary *)status
                             cardDevice:(NSString *)cardDevice;

/* selectedCard is the JackOutputCard value (nil: the clock device).  The
   status' routedOutputCard is a card key, or "clock" for the clock device. */
+ (SoundJackAlertAction)actionForStatus:(NSDictionary *)status
                           selectedCard:(NSString *)selectedCard
                                elapsed:(NSTimeInterval)elapsed
                                timeout:(NSTimeInterval)timeout;

@end
