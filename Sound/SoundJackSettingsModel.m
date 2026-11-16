/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundJackSettingsModel.h"
#import "JackSupport.h"

NSString * const SoundJackDeviceCardId = @"cardId";
NSString * const SoundJackDeviceCardIndex = @"cardIndex";
NSString * const SoundJackDeviceDeviceIndex = @"deviceIndex";

static NSString *cardIdOf(NSDictionary *d)
{
    id v = [d objectForKey:SoundJackDeviceCardId];
    return ([v isKindOfClass:[NSString class]] && [v length] > 0) ? v : nil;
}

static NSInteger deviceIndexOf(NSDictionary *d)
{
    return [[d objectForKey:SoundJackDeviceDeviceIndex] integerValue];
}

@implementation SoundJackSettingsModel

+ (NSArray *)bufferSizes
{
    return @[@64, @128, @256, @512, @1024, @2048, @4096];
}

+ (NSArray *)sampleRates
{
    return @[@44100, @48000, @88200, @96000];
}

+ (NSString *)titleForBufferFrames:(NSUInteger)frames sampleRate:(NSUInteger)rate
{
    double ms = rate > 0 ? 1000.0 * (double)frames / (double)rate : 0.0;
    if (ms < 10.0) {
        return [NSString stringWithFormat:@"%lu frames (%.1f ms)", (unsigned long)frames, ms];
    }
    return [NSString stringWithFormat:@"%lu frames (%.0f ms)", (unsigned long)frames, ms];
}

+ (NSString *)titleForSampleRate:(NSUInteger)rate
{
    if (rate % 1000 == 0) {
        return [NSString stringWithFormat:@"%lu kHz", (unsigned long)(rate / 1000)];
    }
    return [NSString stringWithFormat:@"%.1f kHz", (double)rate / 1000.0];
}

#pragma mark Status

+ (NSString *)defaultStatusPath
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @".cache/gershwin/jack-status.plist"];
}

static NSUInteger unsignedValue(id v)
{
    if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
        long long n = [v longLongValue];
        return n > 0 ? (NSUInteger)n : 0;
    }
    return 0;
}

+ (NSUInteger)statusSampleRate:(NSDictionary *)status
{
    return unsignedValue([status objectForKey:@"sampleRate"]);
}

+ (NSUInteger)statusBufferFrames:(NSDictionary *)status
{
    return unsignedValue([status objectForKey:@"bufferFrames"]);
}

+ (BOOL)statusIsAdopted:(NSDictionary *)status
{
    return [[status objectForKey:@"owner"] isEqual:@"adopted"];
}

+ (BOOL)statusAllowsChangingRate:(NSDictionary *)status
{
    return ![self statusIsAdopted:status];
}

+ (BOOL)statusAllowsChangingBufferSize:(NSDictionary *)status
{
    return YES;
}

+ (NSString *)adoptedHint
{
    return @"This JACK server was started elsewhere. Its sample rate is set "
           @"where it was started; the buffer size can still be changed here.";
}

+ (NSString *)statusTextForStatus:(NSDictionary *)status
                   selectedDeviceName:(NSString *)selectedName
{
    NSString *state = [status objectForKey:@"state"];
    if (![state isKindOfClass:[NSString class]]) {
        return @"Waiting for the sound menu to report the state of JACK...";
    }
    if ([state isEqualToString:@"starting"]) {
        return @"Starting JACK...";
    }
    if ([state isEqualToString:@"failed"] || [state isEqualToString:@"unavailable"]) {
        NSString *message = [status objectForKey:@"message"];
        if (![message isKindOfClass:[NSString class]] || [message length] == 0) {
            message = [state isEqualToString:@"failed"] ? @"unknown error"
                                                        : @"JACK is not installed";
        }
        return [NSString stringWithFormat:@"JACK could not start: %@", message];
    }
    if ([state isEqualToString:@"running"]) {
        if ([self statusIsAdopted:status]) {
            return @"Using the JACK server that is already running "
                   @"(change its settings there)";
        }
        NSUInteger rate = [self statusSampleRate:status];
        NSUInteger frames = [self statusBufferFrames:status];
        NSMutableString *text = [NSMutableString stringWithString:@"JACK is running"];
        NSMutableArray *parts = [NSMutableArray array];
        if (rate > 0) [parts addObject:[self titleForSampleRate:rate]];
        if (frames > 0) {
            [parts addObject:[NSString stringWithFormat:@"%lu frames", (unsigned long)frames]];
        }
        NSString *driven = [status objectForKey:@"drivenDevice"];
        if (![driven isKindOfClass:[NSString class]] || [driven length] == 0) driven = nil;
        id flag = [status objectForKey:@"outputBridged"];
        BOOL haveName = [selectedName length] > 0;
        // The flag is the supervisor's word; without it the names decide
        BOOL bridged = haveName && (flag != nil ? [flag boolValue]
                                                : (driven != nil && ![driven isEqualToString:selectedName]));
        if (!bridged && driven != nil) {
            [parts addObject:[NSString stringWithFormat:@"driving %@", driven]];
        }
        if ([parts count] > 0) {
            [text appendFormat:@": %@", [parts componentsJoinedByString:@", "]];
        }
        if (bridged) {
            [text appendFormat:@" (%@ plays through a bridge)", selectedName];
        }
        return text;
    }
    // disabled, or a state a newer supervisor reports
    return @"JACK is off";
}

#pragma mark Cards

+ (NSDictionary *)deviceDictionaryForStableId:(NSString *)stableId
                                    cardIndex:(NSInteger)cardIndex
                                  deviceIndex:(NSInteger)deviceIndex
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSRange dot = [stableId rangeOfString:@"." options:NSBackwardsSearch];
    if (![stableId hasPrefix:@"hw:"] && dot.location != NSNotFound && dot.location > 0) {
        [d setObject:[stableId substringToIndex:dot.location] forKey:SoundJackDeviceCardId];
    }
    [d setObject:[NSNumber numberWithInteger:cardIndex] forKey:SoundJackDeviceCardIndex];
    [d setObject:[NSNumber numberWithInteger:deviceIndex] forKey:SoundJackDeviceDeviceIndex];
    return d;
}

+ (NSString *)cardKeyForDevice:(NSDictionary *)device amongDevices:(NSArray *)devices
{
    NSString *cardId = cardIdOf(device);
    if (!cardId) return nil;
    NSUInteger onCard = 0;
    for (NSDictionary *d in devices) {
        if ([cardIdOf(d) isEqualToString:cardId]) onCard++;
    }
    if (onCard > 1) {
        return [NSString stringWithFormat:@"%@_%ld", cardId, (long)deviceIndexOf(device)];
    }
    return cardId;
}

+ (NSUInteger)indexOfDeviceNamed:(NSString *)name inDevices:(NSArray *)devices
{
    if ([name length] == 0) return NSNotFound;
    NSUInteger count = [devices count];

    // A card key as written by cardKeyForDevice:amongDevices:
    for (NSUInteger i = 0; i < count; i++) {
        if ([[self cardKeyForDevice:[devices objectAtIndex:i] amongDevices:devices]
                isEqualToString:name]) {
            return i;
        }
    }

    // An ALSA device name
    NSString *rest = name;
    for (NSString *prefix in @[@"plughw:", @"hw:"]) {
        if ([rest hasPrefix:prefix]) {
            rest = [rest substringFromIndex:[prefix length]];
            break;
        }
    }
    if ([rest isEqualToString:name]) return NSNotFound;
    NSString *card = nil;
    NSInteger dev = 0;
    for (NSString *part in [rest componentsSeparatedByString:@","]) {
        if ([part hasPrefix:@"CARD="]) {
            card = [part substringFromIndex:5];
        } else if ([part hasPrefix:@"DEV="]) {
            dev = [[part substringFromIndex:4] integerValue];
        } else if (card == nil) {
            card = part;
        } else {
            dev = [part integerValue];
        }
    }
    if ([card length] == 0) return NSNotFound;
    BOOL numeric = [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
        [NSCharacterSet characterSetWithCharactersInString:card]];
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *d = [devices objectAtIndex:i];
        BOOL cardMatches = numeric
            ? [[d objectForKey:SoundJackDeviceCardIndex] integerValue] == [card integerValue]
            : [cardIdOf(d) isEqualToString:card];
        if (cardMatches && deviceIndexOf(d) == dev) return i;
    }
    return NSNotFound;
}

+ (NSDictionary *)settingsForSelectingDevice:(NSDictionary *)device
                                amongDevices:(NSArray *)devices
                                    isOutput:(BOOL)isOutput
{
    NSString *key = [self cardKeyForDevice:device amongDevices:devices];
    if (!key) return nil;
    return @{ isOutput ? JackSettingOutputCard : JackSettingInputCard : key };
}

+ (BOOL)writeSettings:(NSDictionary *)settings
               atPath:(NSString *)path
                error:(NSString **)error
{
    // The supervisor reads this file every second and acts on every change
    // of it; a choice that is already there is not written again.
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    BOOL same = existing != nil;
    for (NSString *key in settings) {
        if (![[existing objectForKey:key] isEqual:[settings objectForKey:key]]) same = NO;
    }
    if (same) return YES;
    return [JackSupport setSettings:settings atPath:path error:error];
}

@end

@implementation SoundJackStatusReader

- (id)initWithPath:(NSString *)aPath
{
    self = [super init];
    if (self) {
        path = [aPath copy];
    }
    return self;
}

- (void)dealloc
{
    [path release];
    [status release];
    [lastModified release];
    [super dealloc];
}

- (BOOL)refresh
{
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:NULL];
    NSDate *modified = [attrs fileModificationDate];
    if (read && ((modified == nil && lastModified == nil)
                 || (modified && [modified isEqualToDate:lastModified]))) {
        return NO;
    }
    NSDictionary *fresh = modified ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    BOOL changed = !read || ![fresh ?: @{} isEqualToDictionary:status ?: @{}];
    read = YES;
    [lastModified release];
    lastModified = [modified retain];
    [status release];
    status = [fresh retain];
    return changed;
}

- (NSDictionary *)status
{
    return status;
}

@end
