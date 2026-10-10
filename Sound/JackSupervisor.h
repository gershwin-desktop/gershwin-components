/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * JackSupervisor keeps jackd, the alsa_out/alsa_in bridges, the patchbay and
 * the ~/.asoundrc block in the state the Sound settings ask for.  jackd is
 * started on the output the user selected; selecting another device later
 * bridges that one (at most one bridge per direction) instead of restarting
 * jackd, which keeps its device until it is started again.  The Sound menu extra owns the one instance of a session.
 * Foundation only; Linux only (elsewhere -start reports "unavailable" and
 * does nothing).
 *
 * Everything that touches the system goes through a JackSupervisorEnvironment
 * so the logic can be tested against a fake world.
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

extern NSString * const JackSupervisorStatusDidChangeNotification;

/* Keys of -statusDictionary (also written to the status plist). */
extern NSString * const JackStatusState;          // see below
extern NSString * const JackStatusOwner;          // @"own" / @"adopted"
extern NSString * const JackStatusClockDevice;    // hw name, absent for non-ALSA drivers
/* Display name of the device jackd runs on (card and PCM, from
   /proc/asound); absent while it is not present or for non-ALSA drivers. */
extern NSString * const JackStatusDrivenDevice;   // @"drivenDevice"
/* NSNumber BOOL: the applications play to a bridged device, not to the one
   jackd runs on. */
extern NSString * const JackStatusOutputBridged;  // @"outputBridged"
/* Card id (JackDeviceCardId, or @"clock" for jackd's own device) of the
   device the patchbay has connected the applications to, per direction;
   changes in the tick that moves the connections. */
extern NSString * const JackStatusRoutedOutputCard;  // @"routedOutputCard"
extern NSString * const JackStatusRoutedInputCard;   // @"routedInputCard"
extern NSString * const JackStatusSampleRate;     // NSNumber
extern NSString * const JackStatusBufferFrames;   // NSNumber
extern NSString * const JackStatusBridges;        // NSArray of client names
extern NSString * const JackStatusOutputClient;   // client the applications play to
extern NSString * const JackStatusInputClient;    // client the applications record from
extern NSString * const JackStatusMessage;        // human readable, may be absent
extern NSString * const JackStatusLogPath;        // jackd's log

/* Values of JackStatusState. */
extern NSString * const JackStateDisabled;        // UseJack is off
extern NSString * const JackStateUnavailable;     // no jackd or not Linux
extern NSString * const JackStateStarting;
extern NSString * const JackStateRunning;
extern NSString * const JackStateFailed;

/* A child process (jackd or a bridge). */
@protocol JackSupervisorProcess <NSObject>
- (pid_t)processIdentifier;
- (BOOL)isRunning;
@end

/* The calls the supervisor makes on a JACK server; JackConnection has them. */
@protocol JackSupervisorServer <NSObject>
- (NSUInteger)sampleRate;
- (NSUInteger)bufferFrames;
- (BOOL)setBufferFrames:(NSUInteger)frames;
- (NSArray *)allPorts;
- (BOOL)connect:(NSString *)source to:(NSString *)destination;
- (BOOL)disconnect:(NSString *)source from:(NSString *)destination;
- (void)close;
@end

@protocol JackSupervisorEnvironment <NSObject>
- (BOOL)isPlatformSupported;
- (BOOL)isJackdInstalled;
- (BOOL)isALSAJackPluginInstalled;
/* nil means the default server. */
- (NSString *)serverName;
- (NSString *)settingsPath;
- (NSString *)asoundrcPath;
- (NSString *)statusPath;
- (NSString *)logDirectory;
/* "/proc/asound" on a real system. */
- (NSString *)alsaProcRoot;
- (NSTimeInterval)now;
/* Blocks for the grace periods of a kill; a fake advances its clock. */
- (void)sleepFor:(NSTimeInterval)seconds;
/* Processes of the current user whose comm is one of names: entries with
   pid (NSNumber), comm, argv (NSArray). */
- (NSArray *)userProcessesNamed:(NSArray *)names;
/* Whether pid is alive and still runs a program named comm. */
- (BOOL)isProcessAlive:(pid_t)pid named:(NSString *)comm;
/* A negative pid signals the process group. */
- (void)sendSignal:(int)sig toProcess:(pid_t)pid;
/* Starts executable (looked up on the PATH) in its own process group with
   stdout and stderr appended to logPath (truncated first, opened for
   appending so the supervisor can truncate it again under the child);
   fileSizeLimit > 0 caps every file the child writes (RLIMIT_FSIZE, the
   child dies of SIGXFSZ beyond it).  nil with *error on failure. */
- (id<JackSupervisorProcess>)launchExecutable:(NSString *)executable
                                    arguments:(NSArray *)arguments
                                      logPath:(NSString *)logPath
                                fileSizeLimit:(unsigned long long)fileSizeLimit
                                        error:(NSString **)error;
/* "/dev/snd" on a real system: the PCM nodes (pcmC<card>D<dev>p|c). */
- (NSString *)alsaDevRoot;
/* User plus system CPU seconds pid has used; negative when unknown. */
- (double)cpuSecondsOfProcess:(pid_t)pid;
/* Never starts a server; nil when none answers. */
- (id<JackSupervisorServer>)openServer;
/* Calls block on the run loop whenever the settings file may have changed,
   without any periodic wakeup.  NO with *error when that cannot be set up. */
- (BOOL)watchSettingsWithBlock:(void (^)(void))block error:(NSString **)error;
- (void)stopWatchingSettings;
/* A repeating timer on the current run loop; the result is passed back to
   -cancelTimer:. */
- (id)scheduleTimerWithInterval:(NSTimeInterval)interval block:(void (^)(void))block;
- (void)cancelTimer:(id)timer;
@end

/* The real system.  serverName nil means the default server. */
@interface JackSupervisorSystemEnvironment : NSObject <JackSupervisorEnvironment>
{
    NSString *serverName;
    NSFileHandle *watchHandle;
    void (^watchBlock)(void);
    int watchDescriptor;
}
- (id)initWithServerName:(NSString *)name;
/* $HOME relative defaults; subclasses (tests) override the paths. */
@end

@interface JackSupervisor : NSObject
{
    id<JackSupervisorEnvironment> env;
    BOOL started;
    id timer;
    NSTimeInterval timerInterval;
    NSTimeInterval fastUntil;       // tick fast until then while routing is pending
    NSTimeInterval lastBridgeStart;

    NSDictionary *settings;
    NSArray *settingsStamp;
    NSUInteger settingsReadCount;

    NSString *state;
    NSString *message;
    NSDictionary *lastStatus;

    // The server: our own child, or an adopted jackd of the user.
    id<JackSupervisorProcess> jackd;
    pid_t adoptedPid;
    NSArray *serverArguments;       // argv of the running or starting jackd
    NSString *serverClock;          // clock device of that jackd, nil if none
    NSString *drivenName;           // display name of serverClock's device
    NSTimeInterval startedAt;
    NSUInteger failures;
    NSTimeInterval nextAttempt;
    BOOL gaveUp;
    id<JackSupervisorServer> server;
    NSUInteger serverRate;
    NSUInteger serverFrames;

    // Bridge client name -> process (id<JackSupervisorProcess>) or adopted
    // pid (NSNumber).
    NSMutableDictionary *bridges;
    NSMutableDictionary *bridgeFailures;   // name -> {count, next}
    NSMutableDictionary *dyingBridges;     // NSNumber pid -> NSNumber deadline
    NSMutableDictionary *bridgeHealth;     // name -> {identity, cpu, at, hot, logSize}
    NSMutableSet *loggedProblems;

    NSArray *asoundrcStamp;         // of the file as we last left it
    NSString *asoundrcBlock;        // the block we last wrote, nil: none
    NSDictionary *recordedOwn;      // pid and argv of the jackd an earlier run started
    NSString *outputClient;
    NSString *inputClient;
    NSString *routedOutputClient;   // client the applications are connected to
    NSString *routedInputClient;
    NSString *routedOutputCard;
    NSString *routedInputCard;
}

- (id)initWithEnvironment:(id<JackSupervisorEnvironment>)environment;
/* The real system and the default server. */
- (id)init;

/* Reads the settings and from then on follows them.  Does nothing beyond
   watching the settings file while UseJack is off. */
- (void)start;
/* Removes the ~/.asoundrc block, stops the bridges and the jackd this
   supervisor started (an adopted one keeps running), stops watching. */
- (void)stop;
/* One supervision step; the timer calls it every second while JACK is on. */
- (void)tick;
/* Re-reads the settings when the file changed since the last read and,
   when they did and JACK runs, ticks at once. */
- (void)settingsMayHaveChanged;

- (NSDictionary *)statusDictionary;
- (BOOL)isTimerScheduled;
/* Seconds between ticks; 0 without a timer. */
- (NSTimeInterval)timerInterval;
- (NSUInteger)settingsReadCount;

/* The ALSA PCM devices under an /proc/asound-like root: playback and
   capture (arrays of JackSupport device dictionaries).  A card with one PCM
   device is named by its card id, the devices of a card with several by
   <cardid>_<device>; the display name is "<card> - <PCM id>". */
+ (NSDictionary *)alsaDevicesAtRoot:(NSString *)root;
/* The jackd server name argv selects ("default" when none); argv may start
   with the program name. */
+ (NSString *)serverNameForJackdArguments:(NSArray *)argv;
/* The text of the Sound menu's status line, nil when JACK is off. */
+ (NSString *)menuTitleForStatus:(NSDictionary *)status;

@end
