/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundJackAlertPolicy.h"

static NSString * const kRunning = @"running";
static NSString * const kStarting = @"starting";
static NSString * const kClock = @"clock";

static NSString *stringValue(id v)
{
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// "hw:CARD=Audio,DEV=1" and "hw:Audio" name card id "Audio"; the device
// number is nil when the name has none.
static void splitHWName(NSString *hw, NSString **cardId, NSString **device)
{
    *cardId = nil;
    *device = nil;
    if (![hw hasPrefix:@"hw:"]) return;
    for (NSString *part in [[hw substringFromIndex:3] componentsSeparatedByString:@","]) {
        if ([part hasPrefix:@"CARD="]) {
            *cardId = [part substringFromIndex:5];
        } else if ([part hasPrefix:@"DEV="]) {
            *device = [part substringFromIndex:4];
        } else if (*cardId == nil && [part rangeOfString:@"="].location == NSNotFound) {
            *cardId = part;
        }
    }
}

// JackOutputCard is "<id>" or "<id>_<device>" (the suffix only when several
// devices of the card are listed), so "Audio" alone also means device 0.
static BOOL selectedCardIsClock(NSString *selected, NSString *clockHW)
{
    if (selected == nil) return YES;
    NSString *cardId, *device;
    splitHWName(clockHW, &cardId, &device);
    if (cardId == nil) return NO;
    if ([selected isEqualToString:cardId]) {
        return device == nil || [device isEqualToString:@"0"];
    }
    return device != nil &&
        [selected isEqualToString:[NSString stringWithFormat:@"%@_%@", cardId, device]];
}

@implementation SoundJackAlertPolicy

+ (NSString *)playbackDeviceForSettings:(NSDictionary *)settings
                                 status:(NSDictionary *)status
                             cardDevice:(NSString *)cardDevice
{
    BOOL use = [[settings objectForKey:@"UseJack"] boolValue];
    BOOL running = [[status objectForKey:@"state"] isEqual:kRunning];
    return (use && running) ? @"default" : cardDevice;
}

+ (SoundJackAlertAction)actionForStatus:(NSDictionary *)status
                           selectedCard:(NSString *)selectedCard
                                elapsed:(NSTimeInterval)elapsed
                                timeout:(NSTimeInterval)timeout
{
    NSString *state = stringValue([status objectForKey:@"state"]);
    BOOL expired = elapsed >= timeout;

    if ([state isEqualToString:kStarting]) {
        // jackd is coming up, the card is not free to play on before it is
        return expired ? SoundJackAlertPlayOnCard : SoundJackAlertKeepWaiting;
    }
    if (![state isEqualToString:kRunning]) {
        return SoundJackAlertPlayOnCard;
    }

    NSString *routed = stringValue([status objectForKey:@"routedOutputCard"]);
    BOOL confirmed = NO;
    if (routed != nil) {
        if ([routed isEqualToString:kClock]) {
            confirmed = selectedCardIsClock(selectedCard,
                stringValue([status objectForKey:@"clockDevice"]));
        } else {
            confirmed = [routed isEqualToString:selectedCard];
        }
    }
    if (confirmed) return SoundJackAlertPlayDefault;
    return expired ? SoundJackAlertPlayDefaultUnconfirmed : SoundJackAlertKeepWaiting;
}

@end
