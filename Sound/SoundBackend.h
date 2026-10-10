/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Sound Backend Protocol
 * 
 * This protocol defines the interface for audio management backends.
 * Implementations can use ALSA, OSS, PulseAudio, PipeWire,
 * or any other audio system while keeping the UI consistent.
 */

#import <Foundation/Foundation.h>
#import "SoundJackAlertPolicy.h"

// Audio device types
typedef NS_ENUM(NSInteger, AudioDeviceType) {
    AudioDeviceTypeUnknown = 0,
    AudioDeviceTypeBuiltInSpeaker,
    AudioDeviceTypeBuiltInMicrophone,
    AudioDeviceTypeHeadphones,
    AudioDeviceTypeHeadsetMicrophone,
    AudioDeviceTypeUSBAudio,
    AudioDeviceTypeHDMI,
    AudioDeviceTypeDisplayPort,
    AudioDeviceTypeBluetooth,
    AudioDeviceTypeLineIn,
    AudioDeviceTypeLineOut,
    AudioDeviceTypeSPDIF,
    AudioDeviceTypeAggregate,
    AudioDeviceTypeVirtual
};

// Audio device direction
typedef NS_ENUM(NSInteger, AudioDeviceDirection) {
    AudioDeviceDirectionOutput = 0,
    AudioDeviceDirectionInput,
    AudioDeviceDirectionBidirectional
};

// Audio device state
typedef NS_ENUM(NSInteger, AudioDeviceState) {
    AudioDeviceStateUnknown = 0,
    AudioDeviceStateAvailable,
    AudioDeviceStateUnavailable,
    AudioDeviceStateBusy,
    AudioDeviceStateUnplugged
};

// Forward declarations
@class AudioDevice;
@class AudioControl;
@class AudioPort;

#pragma mark - AudioControl

@interface AudioControl : NSObject <NSCopying>
{
    NSString *identifier;
    NSString *name;
    float value;           // 0.0 to 1.0
    float minValue;
    float maxValue;
    BOOL isMuted;
    BOOL hasMuteControl;
    BOOL isReadOnly;
}

@property (copy) NSString *identifier;
@property (copy) NSString *name;
@property float value;
@property float minValue;
@property float maxValue;
@property BOOL isMuted;
@property BOOL hasMuteControl;
@property BOOL isReadOnly;

- (int)percentValue;
- (void)setPercentValue:(int)percent;

@end

#pragma mark - AudioPort

@interface AudioPort : NSObject <NSCopying>
{
    NSString *identifier;
    NSString *name;
    NSString *displayName;
    AudioDeviceType type;
    AudioDeviceDirection direction;
    BOOL isActive;
    BOOL isAvailable;
    int priority;
}

@property (copy) NSString *identifier;
@property (copy) NSString *name;
@property (copy) NSString *displayName;
@property AudioDeviceType type;
@property AudioDeviceDirection direction;
@property BOOL isActive;
@property BOOL isAvailable;
@property int priority;

- (NSImage *)icon;

@end

#pragma mark - AudioDevice

@interface AudioDevice : NSObject <NSCopying>
{
    NSString *identifier;       // Card identifier (e.g., "hw:0" for ALSA)
    NSString *name;             // Internal name
    NSString *displayName;      // User-friendly name
    NSString *manufacturer;
    AudioDeviceType type;
    AudioDeviceDirection direction;
    AudioDeviceState state;
    BOOL isDefault;
    BOOL isSystemDefault;
    
    // Volume controls
    AudioControl *volumeControl;
    AudioControl *balanceControl;
    
    // Available ports (e.g., headphones, speakers)
    NSMutableArray *ports;
    AudioPort *activePort;
    
    // Sample rate and format info
    int sampleRate;
    int channels;
    int bitDepth;
    
    // Card/device info for ALSA
    int cardIndex;
    int deviceIndex;
    NSString *cardName;
    NSString *mixerName;
    NSString *stableDeviceId;  // Persistent cross-reboot identifier (e.g., "Audio.0")
}

@property (copy) NSString *identifier;
@property (copy) NSString *name;
@property (copy) NSString *displayName;
@property (copy) NSString *manufacturer;
@property AudioDeviceType type;
@property AudioDeviceDirection direction;
@property AudioDeviceState state;
@property BOOL isDefault;
@property BOOL isSystemDefault;
@property (retain) AudioControl *volumeControl;
@property (retain) AudioControl *balanceControl;
@property (retain) NSMutableArray *ports;
@property (retain) AudioPort *activePort;
@property int sampleRate;
@property int channels;
@property int bitDepth;
@property int cardIndex;
@property int deviceIndex;
@property (copy) NSString *cardName;
@property (copy) NSString *mixerName;
@property (copy) NSString *stableDeviceId;

- (NSString *)stateString;
- (NSString *)typeString;
- (NSImage *)icon;
- (NSString *)formatDescription;

@end

#pragma mark - AlertSound

@interface AlertSound : NSObject
{
    NSString *name;
    NSString *displayName;
    NSString *path;
    BOOL isSystemSound;
}

@property (copy) NSString *name;
@property (copy) NSString *displayName;
@property (copy) NSString *path;
@property BOOL isSystemSound;

@end

#pragma mark - SoundBackend Protocol

@protocol SoundBackendDelegate;

@protocol SoundBackend <NSObject>

@required

// Backend identification
- (NSString *)backendName;
- (NSString *)backendVersion;
- (BOOL)isAvailable;

// Delegate
@property (assign) id<SoundBackendDelegate> delegate;

// Output device management
- (NSArray *)outputDevices;
- (AudioDevice *)defaultOutputDevice;
- (BOOL)setDefaultOutputDevice:(AudioDevice *)device;
- (AudioDevice *)outputDeviceWithIdentifier:(NSString *)identifier;

// Immediate device switching (force switch even if audio is playing)
- (BOOL)forceImmediateOutputDeviceSwitch:(AudioDevice *)device;
- (BOOL)forceImmediateInputDeviceSwitch:(AudioDevice *)device;

// Input device management  
- (NSArray *)inputDevices;
- (AudioDevice *)defaultInputDevice;
- (BOOL)setDefaultInputDevice:(AudioDevice *)device;
- (AudioDevice *)inputDeviceWithIdentifier:(NSString *)identifier;

// Master volume control (for default output)
- (float)outputVolume;
- (BOOL)setOutputVolume:(float)volume;
- (BOOL)isOutputMuted;
- (BOOL)setOutputMuted:(BOOL)muted;
- (float)outputBalance;
- (BOOL)setOutputBalance:(float)balance;

// Input volume control (for default input)
- (float)inputVolume;
- (BOOL)setInputVolume:(float)volume;
- (BOOL)isInputMuted;
- (BOOL)setInputMuted:(BOOL)muted;

// Input level monitoring
- (float)inputLevel;
- (BOOL)startInputLevelMonitoring;
- (BOOL)stopInputLevelMonitoring;

// Device-specific volume control
- (float)volumeForDevice:(AudioDevice *)device;
- (BOOL)setVolume:(float)volume forDevice:(AudioDevice *)device;
- (BOOL)isMutedForDevice:(AudioDevice *)device;
- (BOOL)setMuted:(BOOL)muted forDevice:(AudioDevice *)device;

// Port selection
- (BOOL)setActivePort:(AudioPort *)port forDevice:(AudioDevice *)device;

// Alert sounds
- (NSArray *)availableAlertSounds;
- (AlertSound *)currentAlertSound;
- (BOOL)setCurrentAlertSound:(AlertSound *)sound;
- (float)alertVolume;
- (BOOL)setAlertVolume:(float)volume;
- (BOOL)playAlertSound:(AlertSound *)sound;
- (AudioDevice *)alertSoundDevice;
- (BOOL)setAlertSoundDevice:(AudioDevice *)device;

// Sound effects settings
- (BOOL)playUserInterfaceSoundEffects;
- (BOOL)setPlayUserInterfaceSoundEffects:(BOOL)play;
- (BOOL)playFeedbackWhenVolumeIsChanged;
- (BOOL)setPlayFeedbackWhenVolumeIsChanged:(BOOL)play;

// Refresh
- (void)refresh;

@optional

// Immediate amixer control switching (backend-specific)
- (BOOL)switchALSAControlImmediately:(NSString *)controlName 
                                 toValue:(NSString *)value 
                                   onCard:(int)cardIndex;
- (NSArray *)getAvailableALSAControls:(int)cardIndex;

// Bluetooth audio (for future expansion)
- (NSArray *)bluetoothAudioDevices;
- (BOOL)connectBluetoothDevice:(AudioDevice *)device;
- (BOOL)disconnectBluetoothDevice:(AudioDevice *)device;

// Aggregate devices
- (NSArray *)aggregateDevices;
- (BOOL)createAggregateDevice:(NSString *)name withDevices:(NSArray *)devices;
- (BOOL)deleteAggregateDevice:(AudioDevice *)device;

// MIDI (for future expansion)
- (NSArray *)midiDevices;

// JACK mode (ALSA backend on Linux)
- (BOOL)jackModeEnabled;
- (SoundJackAlertAction)jackAlertActionForElapsed:(NSTimeInterval)elapsed
                                          timeout:(NSTimeInterval)timeout;

@end

#pragma mark - SoundBackendDelegate

@protocol SoundBackendDelegate <NSObject>

@optional

// Called when device list changes (hotplug)
- (void)soundBackend:(id<SoundBackend>)backend didUpdateOutputDevices:(NSArray *)devices;
- (void)soundBackend:(id<SoundBackend>)backend didUpdateInputDevices:(NSArray *)devices;

// Called when volume changes (from external source)
- (void)soundBackend:(id<SoundBackend>)backend outputVolumeDidChange:(float)volume;
- (void)soundBackend:(id<SoundBackend>)backend inputVolumeDidChange:(float)volume;
- (void)soundBackend:(id<SoundBackend>)backend outputMuteDidChange:(BOOL)muted;
- (void)soundBackend:(id<SoundBackend>)backend inputMuteDidChange:(BOOL)muted;

// Called when default device changes
- (void)soundBackend:(id<SoundBackend>)backend defaultOutputDeviceDidChange:(AudioDevice *)device;
- (void)soundBackend:(id<SoundBackend>)backend defaultInputDeviceDidChange:(AudioDevice *)device;

// Called during input level monitoring
- (void)soundBackend:(id<SoundBackend>)backend inputLevelDidChange:(float)level;

// Called when an error occurs
- (void)soundBackend:(id<SoundBackend>)backend didEncounterError:(NSError *)error;

@end
