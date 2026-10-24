# Sound Preferences Pane

Sound pane that allows you to configure your audio input and output devices, volume levels, and sound effects.
We support ALSA (Advanced Linux Sound Architecture) as the primary backend for Linux systems. For FreeBSD we will add OSS backend support in the future.

## Architecture

The Sound preference pane uses a cross-platform architecture with a backend abstraction layer:

```
┌─────────────────────────────────────────────────────────────────┐
│                          SoundPane                               │
│                      (NSPreferencePane)                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                      SoundController                             │
│               (UI logic, device lists, controls)                 │
│                                                                  │
│  • Output devices tab                                            │
│  • Input devices tab                                             │
│  • Sound Effects tab                                             │
│  • Volume controls and meters                                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           │ SoundBackend protocol
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                    Backend Abstraction                           │
│                  (SoundBackend.h protocol)                       │
└─────────┬───────────────────────────────────────┬───────────────┘
          │                                       │
┌─────────▼─────────┐                   ┌─────────▼─────────┐
│   ALSABackend     │                   │  Future Backends  │
│      (ALSA)       │                   │    (OSS, etc)     │
│                   │                   │                   │
│ Uses amixer for   │                   │ BSD OSS           │
│ all operations    │                   │ PulseAudio        │
└───────────────────┘                   └───────────────────┘
```

### Files

| File | Description |
|------|-------------|
| `SoundPane.h/m` | Preference pane entry point, lifecycle management |
| `SoundController.h/m` | Main UI controller, handles all user interaction |
| `SoundBackend.h` | Protocol defining the backend interface |
| `SoundModels.m` | Data model implementations (AudioDevice, AudioControl, etc.) |
| `ALSABackend.h/m` | ALSA backend using amixer and asound library |
| `SoundInfo.plist` | Bundle metadata |
| `GNUmakefile` | Build configuration |
| `Sound.png` | Preference pane icon (48x48) |
| `alert.aiff` | Default alert sound |
| `sounds/` | Directory containing system alert sounds |

### Data Models

- **AudioDevice**: Represents an audio device (output or input)
- **AudioControl**: Represents a mixer control (volume, mute, balance)
- **AudioPort**: Represents a physical port on a device (headphones, speakers, etc.)

### Backend Protocol

The `SoundBackend` protocol defines the interface for audio management backends:

```objc
@protocol SoundBackend <NSObject>
// Identification
- (NSString *)backendName;
- (BOOL)isAvailable;

// Output device management
- (NSArray *)outputDevices;
- (AudioDevice *)defaultOutputDevice;
- (BOOL)setDefaultOutputDevice:(AudioDevice *)device;

// Input device management
- (NSArray *)inputDevices;
- (AudioDevice *)defaultInputDevice;
- (BOOL)setDefaultInputDevice:(AudioDevice *)device;

// Volume control
- (float)outputVolume;
- (BOOL)setOutputVolume:(float)volume;
- (BOOL)isOutputMuted;
- (BOOL)setOutputMuted:(BOOL)muted;

- (float)inputVolume;
- (BOOL)setInputVolume:(float)volume;
- (BOOL)isInputMuted;
- (BOOL)setInputMuted:(BOOL)muted;

// Alert sounds
- (float)alertVolume;
- (BOOL)setAlertVolume:(float)volume;
- (BOOL)playAlertSound:(NSString *)soundName;
@end
```

### Adding a New Backend

To add support for a new audio system:

1. Create a new class that conforms to `SoundBackend` protocol
2. Implement all required methods
3. In `SoundController.m`, add logic to select the appropriate backend

Example for a FreeBSD OSS backend:

```objc
@interface OSSBackend : NSObject <SoundBackend>
// Implementation using /dev/mixer and /dev/dsp
@end
```

### UI Design

The Sound preference pane follows the classic system preferences design:

**Output Tab:**
- List of output devices (speakers, headphones, HDMI, USB audio)
- Device selection
- Output volume slider with mute checkbox
- Balance slider for stereo devices

**Input Tab:**
- List of input devices (microphone, line-in)
- Device selection
- Input volume slider with mute checkbox
- Input level meter

**Sound Effects Tab:**
- Alert sound selection list with preview
- Alert volume slider
- Output device for alerts popup
- "Play sound effects through" option

### JACK (Linux, only shown when jackd is installed)

Tick "Use JACK" on the Output tab; nothing else is needed.

- The Sound menu extra starts jackd on the output device selected in the list.
- Selecting another output device later bridges it into the running JACK;
  jackd is not restarted and the pane never asks for a restart.
- Applications that only speak ALSA are routed into JACK automatically.
- Input selection works the same way; volume and mute stay on the card's mixer.
- "Buffer size" and "Sample rate" are optional; the status line shows what is running.

### Building

```bash
cd Sound
gmake
sudo -A -E gmake install
```

### Dependencies

- GNUstep Base
- GNUstep GUI  
- PreferencePanes framework
- ALSA library (libasound2) - for Linux
- amixer command line tool

### Future Enhancements

- PulseAudio backend support
- PipeWire backend support
- FreeBSD OSS backend
- Audio MIDI Setup equivalent functionality
- Per-application volume control
- Audio device hotplug detection
