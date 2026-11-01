/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ALSA Backend
 *
 * Uses amixer and aplay command-line tools to interact with ALSA.
 * This approach allows the preference pane to work without linking
 * directly against libasound, making it more portable.
 */

#import "SoundBackend.h"
#import "SoundJackAlertPolicy.h"

@interface ALSABackend : NSObject <SoundBackend>
{
    id<SoundBackendDelegate> delegate;
    
    // Cached data
    NSMutableArray *cachedOutputDevices;
    NSMutableArray *cachedInputDevices;
    AudioDevice *defaultOutput;
    AudioDevice *defaultInput;
    
    // Alert sounds
    NSMutableArray *cachedAlertSounds;
    AlertSound *currentAlert;
    float cachedAlertVolume;
    AudioDevice *alertDevice;
    
    // Settings
    BOOL playUIEffects;
    BOOL playVolumeChangeFeedback;
    
    // Input level monitoring
    dispatch_source_t inputLevelTimer;
    BOOL isMonitoringInputLevel;
    
    // Tool paths
    NSString *amixerPath;
    NSString *aplayPath;
    NSString *arecordPath;
    NSString *alsactlPath;
    
    // Current card for operations
    int currentOutputCard;
    int currentInputCard;
    
    // ALSA configuration file paths
    NSString *asoundrcPath;
    NSString *defaultsFilePath;

    // Whether the in-memory defaults follow the JACK card choices
    BOOL jackModeApplied;
    // jack-status.plist of the supervisor, under the same home as the settings
    NSString *jackStatusPath;

    // Deferred save timer (dispatch-based, replaces performSelector:afterDelay:)
    dispatch_source_t deferredSaveTimer;
}

@property (assign) id<SoundBackendDelegate> delegate;

// Initialization
- (id)initWithHomeDirectory:(NSString *)home;
- (BOOL)findToolPaths;

// Device enumeration
- (void)enumerateDevices;
- (void)parsePlaybackDevices:(NSString *)output;
- (void)parseCaptureDevices:(NSString *)output;
- (AudioDeviceType)guessDeviceType:(NSString *)name cardName:(NSString *)cardName;

// Mixer control
- (NSDictionary *)getMixerControls:(int)cardIndex;
- (BOOL)setMixerControl:(NSString *)control value:(NSString *)value card:(int)cardIndex;
- (float)parseVolumeFromMixerOutput:(NSString *)output;
- (BOOL)parseMuteFromMixerOutput:(NSString *)output;

// Immediate amixer control switching (forces immediate ALSA device change)
- (BOOL)switchALSAControlImmediately:(NSString *)controlName 
                                 toValue:(NSString *)value 
                                   onCard:(int)cardIndex;
- (NSArray *)getAvailableALSAControls:(int)cardIndex;

// Default device management
- (void)loadDefaultDevices;
- (void)pickDefaultFromAsoundrc;
- (NSString *)cardIDForCardIndex:(int)cardIndex;
- (NSString *)hwCardRefForCardIndex:(int)cardIndex;
- (BOOL)saveDefaultDevice:(AudioDevice *)device isOutput:(BOOL)isOutput;
- (BOOL)savePreferences;
- (BOOL)jackModeEnabled;
// The device alerts and feedback sounds play on: "default" (the jack plugin)
// while JACK is used and its server runs, else the selected card.
- (NSString *)alertPlaybackDevice;
// What the pane does after an output device click while JACK is on.
- (SoundJackAlertAction)jackAlertActionForElapsed:(NSTimeInterval)elapsed
                                          timeout:(NSTimeInterval)timeout;
- (void)syncSelectionWithJackMode;
- (void)adoptDefaultOutputIdentifier:(NSString *)identifier;
- (void)adoptDefaultInputIdentifier:(NSString *)identifier;
- (NSString *)buildAsoundrcContent;

// Immediate device switching (force switch even if audio is playing)
- (BOOL)forceImmediateOutputDeviceSwitch:(AudioDevice *)device;
- (BOOL)forceImmediateInputDeviceSwitch:(AudioDevice *)device;

// Alert sounds
- (void)loadAlertSounds;
- (NSString *)alertSoundDirectory;
- (NSString *)userAlertSoundDirectory;

// Input level monitoring
- (void)inputLevelTimerFired;
- (float)measureInputLevel;

// Helper methods
- (NSString *)runCommand:(NSString *)command withArguments:(NSArray *)args;
- (NSString *)runCommandWithPipe:(NSString *)command arguments:(NSArray *)args;
- (NSString *)runCommandCaptureError:(NSString *)command withArguments:(NSArray *)args;
- (void)reportErrorWithMessage:(NSString *)message;

// Device probing
- (BOOL)isOutputDeviceUsable:(AudioDevice *)device;
- (BOOL)isInputDeviceUsable:(AudioDevice *)device;

// Capability probing (for config generation)
- (NSDictionary *)parseStream0ForCard:(int)cardIndex;
- (NSDictionary *)dumpHWParamsForCard:(int)cardIndex
                              device:(int)deviceIndex
                              stream:(NSString *)stream;
- (NSString *)preferredFormatFromFormats:(NSArray *)formats;
- (int)ipcKeyForCard:(int)cardIndex device:(int)deviceIndex;
- (int)suggestedPeriodSizeFromMin:(int)min max:(int)max;
- (int)suggestedBufferSizeFromMin:(int)min max:(int)max;

@end
