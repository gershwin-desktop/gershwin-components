/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * JACK support: run-time loading of libjack, detection of a running jackd,
 * and the pure planners (jackd command line, bridges for the other ALSA
 * devices, patchbay, ~/.asoundrc block) that the Sound pane and the Sound
 * menu extra build their JACK mode on.  Foundation only.
 *
 * Everything that touches the system is Linux-only; on the other platforms
 * the library still builds and every probe reports "not available".  The
 * planners are plain functions of their arguments and work everywhere.
 *
 * Port dictionaries (the element type of -[JackConnection allPorts]):
 *   name        NSString  "client:port"
 *   client      NSString
 *   flags       NSNumber  raw JackPortFlags
 *   isInput / isOutput / isPhysical   NSNumber BOOL
 *   connections NSArray   of port names
 */

#import <Foundation/Foundation.h>

extern NSString * const JackSettingUseJack;          // BOOL, default NO
extern NSString * const JackSettingBufferFrames;     // int, default 1024
extern NSString * const JackSettingSampleRate;       // int, default 48000
/* The devices the user selected in the Sound pane while JACK is on: a card
   id as the supervisor names devices ("Audio", "HDMI_3").  jackd is started
   on the selected output; every other selected device is bridged. */
extern NSString * const JackSettingOutputCard;       // "JackOutputCard"
extern NSString * const JackSettingInputCard;        // "JackInputCard"
/* The ALSA defaults the Sound pane stores ("<card id>.<device>"): the
   selection when no JACK card was chosen.  Read only. */
extern NSString * const JackSettingALSAOutput;       // "defaultOutput"
extern NSString * const JackSettingALSAInput;        // "defaultInput"

extern NSString * const JackClientName;              // "gershwin-sound"

/* Keys of the jackd settings dictionary for +jackdArgumentsForSettings:. */
extern NSString * const JackdDevice;                 // required, e.g. "hw:0"
extern NSString * const JackdSampleRate;             // default 48000
extern NSString * const JackdBufferFrames;           // default 1024
extern NSString * const JackdPeriods;                // default 3
extern NSString * const JackdServerName;             // optional

/* Keys of the device dictionaries given to the bridge planner. */
extern NSString * const JackDeviceCardId;            // stable card id string
extern NSString * const JackDeviceCardIndex;         // optional NSNumber
extern NSString * const JackDeviceHW;                // "hw:CARD=Audio,DEV=0"
extern NSString * const JackDeviceDirection;         // @"playback" / @"capture"
extern NSString * const JackDeviceDisplayName;

/* A connection to a running JACK server, opened without ever starting one.
   Reading works on a client that was never activated; connecting,
   disconnecting and changing the buffer size need an activated client
   (jackd 1.9.22: jack_connect returns -1 and jack_set_buffer_size has no
   effect otherwise), so those methods activate lazily with an empty process
   callback.  Activation costs one wakeup per period for as long as the
   connection stays open, so keep a connection that only polls ports closed
   between polls.  Methods are serialised, so one connection may be handed
   to a background thread. */
@interface JackConnection : NSObject
{
    void *client;
    BOOL activated;
}

/* NO when libjack.so.0 cannot be loaded (always NO off Linux). */
+ (BOOL)isLibraryAvailable;

/* nil when libjack is missing or no server of that name runs.  Never starts
   a server.  serverName nil means the default server. */
+ (JackConnection *)openWithServerName:(NSString *)serverName;
+ (JackConnection *)openWithServerName:(NSString *)serverName
                            clientName:(NSString *)clientName;

- (BOOL)isOpen;
- (NSUInteger)sampleRate;
- (NSUInteger)bufferFrames;
/* The server applies the change asynchronously; read -bufferFrames again. */
- (BOOL)setBufferFrames:(NSUInteger)frames;
/* Audio ports only; nil when the connection is closed. */
- (NSArray *)allPorts;
- (BOOL)connect:(NSString *)source to:(NSString *)destination;
- (BOOL)disconnect:(NSString *)source from:(NSString *)destination;
/* Registers an audio port on this client (flags are JackPortFlags) and
   activates, so that other clients can connect to it.  Used by tests that
   have to impersonate applications. */
- (BOOL)registerAudioPortNamed:(NSString *)name flags:(unsigned long)flags;
- (void)close;
@end

@interface JackSupport : NSObject

#pragma mark Detection

/* Pure: the pids of the entries whose uid is uid and whose comm is jackd or
   jackdbus.  Entries: pid (NSNumber), uid (NSNumber), comm, argv (NSArray). */
+ (NSArray *)jackdProcessIDsInTable:(NSArray *)table forUID:(uid_t)uid;
/* Same filter, returning the entries. */
+ (NSArray *)jackdProcessesInTable:(NSArray *)table forUID:(uid_t)uid;
/* The process table of the system (Linux: /proc); empty elsewhere. */
+ (NSArray *)processTable;
/* jackd / jackdbus processes of the current user. */
+ (NSArray *)jackdProcessIDs;
+ (NSArray *)jackdProcesses;

/* Pure: an executable jackd on the PATH string or in /usr/bin, /usr/local/bin. */
+ (BOOL)isJackdAvailableWithPATH:(NSString *)path
                      fileExists:(BOOL (^)(NSString *path))isExecutable;
+ (BOOL)isJackdAvailable;

/* A connection to the server of the current user, or nil when there is no
   jackd process or it does not answer. */
+ (JackConnection *)runningServerNamed:(NSString *)serverName;
+ (JackConnection *)runningServer;

#pragma mark jackd command line

/* Arguments after the program name, or nil with *error set. */
+ (NSArray *)jackdArgumentsForSettings:(NSDictionary *)settings
                                 error:(NSString **)error;
/* The device the alsa driver of a running jackd uses ("hw:0" when the
   command line names none), nil for any other driver. argv may start with
   the program name. */
+ (NSString *)clockDeviceForJackdArguments:(NSArray *)argv;

#pragma mark The selected devices and their bridges

/* Whether a device dictionary is the device clockDevice (a hw name such as
   "hw:0" or "hw:CARD=PCH,DEV=0") names. */
+ (BOOL)isDevice:(NSDictionary *)device clockDevice:(NSString *)clockDevice;

/* The present device the user selected: jackCard (a JackDeviceCardId) when
   set, else alsaDefault (JackSettingALSAOutput / Input form).  nil when no
   selection was made or the selected device is not present; *selection is
   the selection's name either way (nil: none made). */
+ (NSDictionary *)selectedDeviceInDevices:(NSArray *)devices
                                 jackCard:(NSString *)jackCard
                              alsaDefault:(NSString *)alsaDefault
                                selection:(NSString **)selection;

+ (NSString *)bridgeClientNameForCardId:(NSString *)cardId
                              direction:(NSString *)direction;
/* playback / capture: the devices to bridge (JackDevice* keys); the
   supervisor passes only the selected ones, so at most one each.
   running: client names of the bridge processes alive now.
   Returns start (array of {name, executable, arguments, hw, direction}),
   stop (array of client names) and errors (array of strings). */
+ (NSDictionary *)bridgePlanForPlaybackDevices:(NSArray *)playback
                                captureDevices:(NSArray *)capture
                                runningBridges:(NSArray *)running
                                   clockDevice:(NSString *)clockDevice
                                    sampleRate:(NSUInteger)rate
                                  bufferFrames:(NSUInteger)frames
                                       periods:(NSUInteger)periods
                                    serverName:(NSString *)serverName;

#pragma mark Patchbay

/* outputClient / inputClient are the JACK client names of the selected
   devices ("system" for the clock device, "gsout-<id>" / "gsin-<id>" for a
   bridged one); nil means none selected.  Returns connect and disconnect
   (arrays of @[sourcePort, destinationPort]; apply disconnects first) and
   problems (strings).  A side whose device is missing does nothing. */
+ (NSDictionary *)patchbayPlanForPorts:(NSArray *)ports
                          outputClient:(NSString *)outputClient
                           inputClient:(NSString *)inputClient;

#pragma mark ~/.asoundrc

/* The managed block naming the system ports. */
+ (NSString *)asoundrcJackBlock;
/* The block naming the first two of the given port names for each direction
   (one port serves both channels); a direction without any valid port name
   gets no section, which makes the jack plugin refuse that direction only. */
+ (NSString *)asoundrcJackBlockWithPlaybackPorts:(NSArray *)playback
                                    capturePorts:(NSArray *)capture;
/* The block for the clients the patchbay routes to: their device ports, or,
   when a client has none, those of the system client or any other device. */
+ (NSString *)asoundrcJackBlockForPorts:(NSArray *)ports
                           outputClient:(NSString *)outputClient
                            inputClient:(NSString *)inputClient;
+ (BOOL)asoundrcHasJackBlock:(NSString *)text;
/* Appends the managed block, or replaces it in place when present.  nil with
   *error set when an existing block is damaged (BEGIN without END). */
+ (NSString *)asoundrcByApplyingJackBlock:(NSString *)block
                                       to:(NSString *)text
                                    error:(NSString **)error;
/* The same with +asoundrcJackBlock. */
+ (NSString *)asoundrcByApplyingJackBlockTo:(NSString *)text
                                      error:(NSString **)error;
/* Removes the block; the text is byte-identical to what it was before the
   block was first applied.  Text without a block is returned unchanged. */
+ (NSString *)asoundrcByRemovingJackBlockFrom:(NSString *)text
                                        error:(NSString **)error;

#pragma mark Settings (sound-defaults.plist)

+ (NSString *)defaultSettingsPath;
/* UseJack, buffer and rate with defaults filled in, bad values replaced by
   the default; the two card keys and the two ALSA defaults only when set.
   Other keys (an old JackClockDevice among them) are ignored. */
+ (NSDictionary *)settingsAtPath:(NSString *)path;
/* Merges the given keys into the plist, leaving every other key alone;
   NSNull clears the card keys.
   NO with *error set for an invalid value or a failed write. */
+ (BOOL)setSettings:(NSDictionary *)settings
             atPath:(NSString *)path
              error:(NSString **)error;
+ (NSDictionary *)settings;
+ (BOOL)setSettings:(NSDictionary *)settings error:(NSString **)error;

@end
