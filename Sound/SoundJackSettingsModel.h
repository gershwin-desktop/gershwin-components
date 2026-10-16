/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The decisions behind the JACK box of the Sound pane, kept free of any
 * view so they can be tested on their own: the choices of the popups, the
 * texts, which controls the state of the server allows, and how ALSA cards
 * are named in the settings file.  Foundation only.
 *
 * Device dictionaries (the element type of the device arrays) have the keys
 *   cardId       NSString  ALSA card id as in /proc/asound/cards
 *   cardIndex    NSNumber  card number
 *   deviceIndex  NSNumber  device number on the card
 */

#import <Foundation/Foundation.h>

extern NSString * const SoundJackDeviceCardId;
extern NSString * const SoundJackDeviceCardIndex;
extern NSString * const SoundJackDeviceDeviceIndex;

@interface SoundJackSettingsModel : NSObject

#pragma mark Choices

+ (NSArray *)bufferSizes;      // NSNumber frames: 64 ... 4096
+ (NSArray *)sampleRates;      // NSNumber Hz: 44100, 48000, 88200, 96000

/* "1024 frames (21 ms)"; below 10 ms one decimal is shown. */
+ (NSString *)titleForBufferFrames:(NSUInteger)frames sampleRate:(NSUInteger)rate;
/* "48 kHz", "44.1 kHz" */
+ (NSString *)titleForSampleRate:(NSUInteger)rate;

#pragma mark Status (jack-status.plist)

+ (NSString *)defaultStatusPath;
/* "JACK is running: 48 kHz, 1024 frames, driving Built-in Audio" and so on
   for every state.  The status' drivenDevice names the device jackd runs on;
   when the selected output is another one (outputBridged, or different
   names) the text says that the selected device plays through a bridge. */
+ (NSString *)statusTextForStatus:(NSDictionary *)status
                   selectedDeviceName:(NSString *)selectedName;
/* The numbers of a status; 0 when absent.  A status written as a text plist
   carries them as strings, so both forms are read. */
+ (NSUInteger)statusSampleRate:(NSDictionary *)status;
+ (NSUInteger)statusBufferFrames:(NSDictionary *)status;
/* The server was not started by us (owner = adopted). */
+ (BOOL)statusIsAdopted:(NSDictionary *)status;
/* The sample rate of an adopted server belongs to its owner. */
+ (BOOL)statusAllowsChangingRate:(NSDictionary *)status;
/* Only a server we do not own is changed live; ours restarts on the next
   settings change, so every state accepts a new buffer size. */
+ (BOOL)statusAllowsChangingBufferSize:(NSDictionary *)status;
+ (NSString *)adoptedHint;

#pragma mark ALSA cards in the settings

/* The device dictionary of an audio device from its stable id
   ("<cardId>.<device>", or "hw:N,M" when the card has no id: then no cardId). */
+ (NSDictionary *)deviceDictionaryForStableId:(NSString *)stableId
                                    cardIndex:(NSInteger)cardIndex
                                  deviceIndex:(NSInteger)deviceIndex;

/* Name of a device in JackOutputCard / JackInputCard: the card id, plus
   "_<device>" when several devices of the list belong to that card.  nil
   when the card has no id. */
+ (NSString *)cardKeyForDevice:(NSDictionary *)device
                       amongDevices:(NSArray *)devices;
/* Index in devices of the entry a card key or hw name ("hw:0",
   "hw:CARD=Audio,DEV=1", "hw:Audio", "Audio_1") names, NSNotFound if none. */
+ (NSUInteger)indexOfDeviceNamed:(NSString *)name inDevices:(NSArray *)devices;

/* What choosing a device writes: the card key under the output or the input
   key, nothing else.  nil when the device has no card id. */
+ (NSDictionary *)settingsForSelectingDevice:(NSDictionary *)device
                                amongDevices:(NSArray *)devices
                                    isOutput:(BOOL)isOutput;

/* JackSupport's settings merge, skipping the write when the file already
   holds these values.  NO with *error set on failure. */
+ (BOOL)writeSettings:(NSDictionary *)settings
               atPath:(NSString *)path
                error:(NSString **)error;

@end

/* Reads jack-status.plist, and only again after its modification time
   changed.  The supervisor replaces the file atomically, so a read never
   sees half a file; a missing or unreadable file reads as "no status". */
@interface SoundJackStatusReader : NSObject
{
    NSString *path;
    NSDictionary *status;
    NSDate *lastModified;
    BOOL read;
}
- (id)initWithPath:(NSString *)aPath;
/* YES when what -status returns changed since the last call. */
- (BOOL)refresh;
- (NSDictionary *)status;
@end
