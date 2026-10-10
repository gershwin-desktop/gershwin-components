/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "JackSupervisor.h"
#import "JackSupport.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/inotify.h>
#endif

NSString * const JackSupervisorStatusDidChangeNotification = @"JackSupervisorStatusDidChangeNotification";

NSString * const JackStatusState = @"state";
NSString * const JackStatusOwner = @"owner";
NSString * const JackStatusClockDevice = @"clockDevice";
NSString * const JackStatusDrivenDevice = @"drivenDevice";
NSString * const JackStatusOutputBridged = @"outputBridged";
NSString * const JackStatusRoutedOutputCard = @"routedOutputCard";
NSString * const JackStatusRoutedInputCard = @"routedInputCard";
NSString * const JackStatusSampleRate = @"sampleRate";
NSString * const JackStatusBufferFrames = @"bufferFrames";
NSString * const JackStatusBridges = @"bridgedCards";
NSString * const JackStatusOutputClient = @"outputClient";
NSString * const JackStatusInputClient = @"inputClient";
NSString * const JackStatusMessage = @"message";
NSString * const JackStatusLogPath = @"logPath";

NSString * const JackStateDisabled = @"disabled";
NSString * const JackStateUnavailable = @"unavailable";
NSString * const JackStateStarting = @"starting";
NSString * const JackStateRunning = @"running";
NSString * const JackStateFailed = @"failed";

// Not shown to the UI: lets a later supervisor recognise the jackd an
// earlier one started (Menu crashed) as its own rather than the user's.
static NSString * const kStatusOwnPid = @"ownJackdPid";
static NSString * const kStatusOwnArguments = @"ownJackdArguments";

static const NSTimeInterval kTickInterval = 1.0;
// While a new selection waits for its bridge's ports the routing is checked
// this often, so it moves as soon as the bridge has registered; bounded by
// kFastTickWindow so a bridge that never comes up does not keep it fast.
static const NSTimeInterval kFastTickInterval = 0.2;
static const NSTimeInterval kFastTickWindow = 5.0;
static const NSTimeInterval kStartTimeout = 10.0;
static const NSTimeInterval kJackdGrace = 3.0;
static const NSTimeInterval kBridgeGrace = 2.0;
static const NSUInteger kMaxFailures = 5;
static const NSUInteger kBridgePeriods = 3;
// jackd 1.9.22 logged "Broken pipe" for clients that registered while
// several others were registering at the same time; one bridge start per
// second keeps their registrations apart.
static const NSTimeInterval kBridgeStagger = 1.0;

// A bridge whose device went away under it (USB re-enumeration) can spin on
// the dead handle, printing an error per period: the alsa_in of a USB mic
// wrote 978 MB of "err = -19" in under a minute at 37% CPU.  Logs are cut
// back in the tick, a bridge cannot write past kBridgeFileSizeLimit at all,
// and a bridge that burns CPU or floods its log is restarted.
static const unsigned long long kLogTruncateBytes = 256 * 1024;
static const unsigned long long kBridgeFileSizeLimit = 1024 * 1024;
static const double kBridgeMaxCPU = 0.5;             // of one core
static const NSUInteger kBridgeHotTicks = 3;
static const double kBridgeMaxLogRate = 64 * 1024;   // bytes per second

static NSString * const kSystemClient = @"system";

static NSTimeInterval backoffAfter(NSUInteger failures)
{
    // 2, 4, 8, ... capped at a minute.
    NSTimeInterval delay = 1.0;
    for (NSUInteger i = 0; i < failures && delay < 60.0; i++) delay *= 2.0;
    return delay > 60.0 ? 60.0 : delay;
}

// Identity of a file version: an atomic replace changes the inode, an
// in-place write the time or size; seconds alone would miss two writes in
// the same second.
static NSArray *fileStamp(NSString *path)
{
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) return [NSArray array];
    long long nsec = (long long)st.st_mtim.tv_nsec;
    return [NSArray arrayWithObjects:
        [NSNumber numberWithUnsignedLongLong:(unsigned long long)st.st_ino],
        [NSNumber numberWithLongLong:(long long)st.st_mtime],
        [NSNumber numberWithLongLong:nsec],
        [NSNumber numberWithLongLong:(long long)st.st_size], nil];
}

static unsigned long long fileSize(NSString *path)
{
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) return 0;
    return (unsigned long long)st.st_size;
}

#pragma mark - System environment

@interface JackTaskProcess : NSObject <JackSupervisorProcess>
{
    NSTask *task;
}
- (id)initWithTask:(NSTask *)t;
@end

@implementation JackTaskProcess
- (id)initWithTask:(NSTask *)t
{
    if ((self = [super init]) != nil) task = [t retain];
    return self;
}
- (void)dealloc
{
    [task release];
    [super dealloc];
}
- (pid_t)processIdentifier { return [task processIdentifier]; }
- (BOOL)isRunning { return [task isRunning]; }
@end

@interface JackConnection (JackSupervisorServer) <JackSupervisorServer>
@end
@implementation JackConnection (JackSupervisorServer)
@end

@interface JackTimerTarget : NSObject
{
    void (^block)(void);
}
- (id)initWithBlock:(void (^)(void))b;
- (void)fire:(NSTimer *)t;
@end

@implementation JackTimerTarget
- (id)initWithBlock:(void (^)(void))b
{
    if ((self = [super init]) != nil) block = [b copy];
    return self;
}
- (void)dealloc
{
    [block release];
    [super dealloc];
}
- (void)fire:(NSTimer *)t
{
    (void)t;
    block();
}
@end

@interface JackSupport (JackSupervisorProcessTable)
+ (NSArray *)processTableMatching:(BOOL (^)(NSString *comm))wanted;
@end

@implementation JackSupervisorSystemEnvironment

- (id)initWithServerName:(NSString *)name
{
    if ((self = [super init]) != nil) {
        serverName = [name copy];
        watchDescriptor = -1;
    }
    return self;
}

- (id)init
{
    return [self initWithServerName:nil];
}

- (void)dealloc
{
    [self stopWatchingSettings];
    [serverName release];
    [super dealloc];
}

- (BOOL)isPlatformSupported
{
#ifdef __linux__
    return YES;
#else
    return NO;
#endif
}

- (BOOL)isJackdInstalled
{
    return [JackSupport isJackdAvailable] && [JackConnection isLibraryAvailable];
}

- (BOOL)isALSAJackPluginInstalled
{
    // ALSA looks for its plugins in the directory it was built with; the
    // distributions use one of these.
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:
        @"/usr/lib/alsa-lib", @"/usr/lib64/alsa-lib", @"/usr/local/lib/alsa-lib", nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:@"/usr/lib" error:NULL]) {
        // Debian's multiarch directories, e.g. x86_64-linux-gnu.
        if ([entry rangeOfString:@"-linux-"].location != NSNotFound) {
            [dirs addObject:[NSString stringWithFormat:@"/usr/lib/%@/alsa-lib", entry]];
        }
    }
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:@"libasound_module_pcm_jack.so"];
        if ([fm fileExistsAtPath:path]) return YES;
    }
    return NO;
}

- (NSString *)serverName { return serverName; }

- (NSString *)settingsPath { return [JackSupport defaultSettingsPath]; }

- (NSString *)asoundrcPath
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@".asoundrc"];
}

- (NSString *)statusPath
{
    return [[self logDirectory] stringByAppendingPathComponent:@"jack-status.plist"];
}

- (NSString *)logDirectory
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@".cache/gershwin"];
}

- (NSString *)alsaProcRoot { return @"/proc/asound"; }

- (NSString *)alsaDevRoot { return @"/dev/snd"; }

- (double)cpuSecondsOfProcess:(pid_t)pid
{
    // utime and stime are fields 14 and 15; the command name before them may
    // contain spaces and parentheses, so count from the last ')'.
    NSString *stat = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"/proc/%d/stat", (int)pid]
                                               encoding:NSUTF8StringEncoding error:NULL];
    NSRange paren = [stat rangeOfString:@")" options:NSBackwardsSearch];
    if (paren.location == NSNotFound) return -1;
    NSArray *fields = [[stat substringFromIndex:NSMaxRange(paren)]
        componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *f in fields) if ([f length] > 0) [words addObject:f];
    // words[0] is field 3 (state).
    if ([words count] < 13) return -1;
    long ticks = sysconf(_SC_CLK_TCK);
    if (ticks <= 0) return -1;
    return ([[words objectAtIndex:11] longLongValue] + [[words objectAtIndex:12] longLongValue]) / (double)ticks;
}

- (NSTimeInterval)now { return [NSDate timeIntervalSinceReferenceDate]; }

- (void)sleepFor:(NSTimeInterval)seconds
{
    [NSThread sleepForTimeInterval:seconds];
}

- (NSArray *)userProcessesNamed:(NSArray *)names
{
    NSArray *table = [JackSupport processTableMatching:^BOOL(NSString *comm) {
        return [names containsObject:comm];
    }];
    NSMutableArray *mine = [NSMutableArray array];
    uid_t uid = getuid();
    for (NSDictionary *entry in table) {
        if ([[entry objectForKey:@"uid"] unsignedIntValue] == uid) [mine addObject:entry];
    }
    return mine;
}

- (BOOL)isProcessAlive:(pid_t)pid named:(NSString *)comm
{
#ifdef __linux__
    NSString *path = [NSString stringWithFormat:@"/proc/%d/comm", (int)pid];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text == nil) return NO;
    // A zombie keeps its comm until it is reaped; it is gone all the same.
    NSString *stat = [NSString stringWithContentsOfFile:
        [NSString stringWithFormat:@"/proc/%d/stat", (int)pid]
                                               encoding:NSUTF8StringEncoding error:NULL];
    NSRange paren = [stat rangeOfString:@")" options:NSBackwardsSearch];
    if (paren.location != NSNotFound && paren.location + 2 < [stat length]
        && [stat characterAtIndex:paren.location + 2] == 'Z') {
        return NO;
    }
    return [[text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:comm];
#else
    (void)pid;
    (void)comm;
    return NO;
#endif
}

- (void)sendSignal:(int)sig toProcess:(pid_t)pid
{
    if (kill(pid, sig) != 0 && errno != ESRCH) {
        NSLog(@"[JACK] kill(%d, %d) failed: %s", (int)pid, sig, strerror(errno));
    }
}

- (id<JackSupervisorProcess>)launchExecutable:(NSString *)executable
                                    arguments:(NSArray *)arguments
                                      logPath:(NSString *)logPath
                                fileSizeLimit:(unsigned long long)fileSizeLimit
                                        error:(NSString **)error
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:[logPath stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        if (error) *error = [NSString stringWithFormat:@"cannot create %@: %@",
                             [logPath stringByDeletingLastPathComponent], dirError];
        return nil;
    }
    // Truncated per start: the log is for the run that is failing now.
    // Appending, so truncating it later under the running child does not
    // leave the child writing at its old offset into a sparse file.
    int fd = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"cannot open %@: %s", logPath, strerror(errno)];
        return nil;
    }
    NSFileHandle *log = [[[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES] autorelease];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    // NSTask puts the child into its own process group, so killing the group
    // cannot reach Menu.  The limit is set by the shell between fork and exec
    // (NSTask has no hook there; setting it in Menu would hit Menu's own
    // threads).  POSIX counts ulimit -f in 512-byte blocks, bash outside
    // POSIX mode in 1024: the cap is the limit or twice it.  The program is
    // looked up on the PATH by exec; arguments are passed as "$@", never
    // parsed by the shell.
    unsigned long long blocks = fileSizeLimit > 0 ? (fileSizeLimit + 511) / 512 : 0;
    NSString *script = blocks > 0
        ? [NSString stringWithFormat:@"ulimit -f %llu && exec \"$@\"", blocks]
        : @"exec \"$@\"";
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[[NSArray arrayWithObjects:@"-c", script, @"sh", executable, nil]
                           arrayByAddingObjectsFromArray:arguments]];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardOutput:log];
    [task setStandardError:log];
    @try {
        [task launch];
    } @catch (NSException *e) {
        if (error) *error = [NSString stringWithFormat:@"cannot start %@: %@", executable, [e reason]];
        return nil;
    }
    return [[[JackTaskProcess alloc] initWithTask:task] autorelease];
}

- (id<JackSupervisorServer>)openServer
{
    return [JackConnection openWithServerName:serverName];
}

- (BOOL)watchSettingsWithBlock:(void (^)(void))block error:(NSString **)error
{
#ifdef __linux__
    [self stopWatchingSettings];
    NSString *dir = [[self settingsPath] stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    // The pane writes the file by rename, which replaces the inode; only a
    // watch on the directory sees that.  The directory has to exist for it.
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                    attributes:nil error:&dirError]) {
        if (error) *error = [NSString stringWithFormat:@"cannot create %@: %@", dir, dirError];
        return NO;
    }
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"inotify_init1: %s", strerror(errno)];
        return NO;
    }
    watchDescriptor = inotify_add_watch(fd, [dir fileSystemRepresentation],
                                        IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE);
    if (watchDescriptor < 0) {
        if (error) *error = [NSString stringWithFormat:@"inotify_add_watch %@: %s", dir, strerror(errno)];
        close(fd);
        return NO;
    }
    watchBlock = [block copy];
    watchHandle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsDirectoryChanged:)
                                                 name:NSFileHandleDataAvailableNotification
                                               object:watchHandle];
    [watchHandle waitForDataInBackgroundAndNotify];
    return YES;
#else
    (void)block;
    if (error) *error = @"settings watching is only implemented on Linux";
    return NO;
#endif
}

- (void)settingsDirectoryChanged:(NSNotification *)notification
{
    (void)notification;
#ifdef __linux__
    char buf[4096];
    // Drained completely so one change does not wake us twice.
    while (read([watchHandle fileDescriptor], buf, sizeof(buf)) > 0) { }
    [watchHandle waitForDataInBackgroundAndNotify];
    if (watchBlock) watchBlock();
#endif
}

- (void)stopWatchingSettings
{
    if (watchHandle != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSFileHandleDataAvailableNotification
                                                      object:watchHandle];
        [watchHandle release];
        watchHandle = nil;
    }
    watchDescriptor = -1;
    [watchBlock release];
    watchBlock = nil;
}

- (id)scheduleTimerWithInterval:(NSTimeInterval)interval block:(void (^)(void))block
{
    JackTimerTarget *target = [[[JackTimerTarget alloc] initWithBlock:block] autorelease];
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:interval target:target
                                                selector:@selector(fire:)
                                                userInfo:nil repeats:YES];
    return t;
}

- (void)cancelTimer:(id)t
{
    [(NSTimer *)t invalidate];
}

@end

#pragma mark - A taken-over jackd

@interface JackPidProcess : NSObject <JackSupervisorProcess>
{
    pid_t pid;
    id<JackSupervisorEnvironment> env;
}
- (id)initWithPid:(pid_t)p environment:(id<JackSupervisorEnvironment>)e;
@end

@implementation JackPidProcess
- (id)initWithPid:(pid_t)p environment:(id<JackSupervisorEnvironment>)e
{
    if ((self = [super init]) != nil) {
        pid = p;
        env = [(id)e retain];
    }
    return self;
}
- (void)dealloc
{
    [(id)env release];
    [super dealloc];
}
- (pid_t)processIdentifier { return pid; }
- (BOOL)isRunning
{
    return [env isProcessAlive:pid named:@"jackd"] || [env isProcessAlive:pid named:@"jackdbus"];
}
@end

#pragma mark - Supervisor

@implementation JackSupervisor

- (id)initWithEnvironment:(id<JackSupervisorEnvironment>)environment
{
    if ((self = [super init]) != nil) {
        env = [environment retain];
        state = [JackStateDisabled retain];
        bridges = [[NSMutableDictionary alloc] init];
        bridgeFailures = [[NSMutableDictionary alloc] init];
        dyingBridges = [[NSMutableDictionary alloc] init];
        loggedProblems = [[NSMutableSet alloc] init];
        bridgeHealth = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (id)init
{
    JackSupervisorSystemEnvironment *system =
        [[[JackSupervisorSystemEnvironment alloc] initWithServerName:nil] autorelease];
    return [self initWithEnvironment:system];
}

- (void)dealloc
{
    // No notification from a dying object.
    [self stopPosting:NO];
    [env release];
    [settings release];
    [settingsStamp release];
    [state release];
    [message release];
    [lastStatus release];
    [(id)jackd release];
    [serverArguments release];
    [serverClock release];
    [drivenName release];
    [(id)server release];
    [bridges release];
    [bridgeFailures release];
    [dyingBridges release];
    [loggedProblems release];
    [bridgeHealth release];
    [asoundrcStamp release];
    [asoundrcBlock release];
    [recordedOwn release];
    [outputClient release];
    [inputClient release];
    [routedOutputClient release];
    [routedInputClient release];
    [routedOutputCard release];
    [routedInputCard release];
    [super dealloc];
}

- (NSUInteger)settingsReadCount { return settingsReadCount; }
- (BOOL)isTimerScheduled { return timer != nil; }

#pragma mark Small helpers

- (void)setState:(NSString *)s message:(NSString *)m
{
    ASSIGN(state, s);
    ASSIGN(message, m);
}

// The same problem is reported once, not every second.
- (void)logOnce:(NSString *)text
{
    if ([loggedProblems containsObject:text]) return;
    [loggedProblems addObject:text];
    NSLog(@"[JACK] %@", text);
}

- (NSString *)jackdLogPath
{
    return [[env logDirectory] stringByAppendingPathComponent:@"jackd.log"];
}

- (BOOL)useJack
{
    return [[settings objectForKey:JackSettingUseJack] boolValue];
}

- (NSString *)effectiveServerName
{
    NSString *name = [env serverName];
    return name ? name : @"default";
}

#pragma mark Timer

- (void)ensureTimer
{
    if (timer != nil) return;
    __block JackSupervisor *me = self;    // the supervisor cancels the timer before it goes
    timerInterval = [env now] < fastUntil ? kFastTickInterval : kTickInterval;
    timer = [[env scheduleTimerWithInterval:timerInterval block:^{ [me tick]; }] retain];
}

// Fast while a selection waits for its bridge, otherwise once a second.
- (void)adjustTimer
{
    if (timer == nil) return;
    BOOL pending = [env now] < fastUntil
        && !([outputClient isEqual:routedOutputClient] && [inputClient isEqual:routedInputClient]);
    if (!pending) fastUntil = 0;
    NSTimeInterval want = pending ? kFastTickInterval : kTickInterval;
    if (want == timerInterval) return;
    [self cancelTimer];
    [self ensureTimer];
}

- (NSTimeInterval)timerInterval
{
    return timer != nil ? timerInterval : 0;
}

- (void)cancelTimer
{
    if (timer == nil) return;
    [env cancelTimer:timer];
    [timer release];
    timer = nil;
}

#pragma mark Status

- (NSDictionary *)statusDictionary
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:state forKey:JackStatusState];
    if (message) [d setObject:message forKey:JackStatusMessage];
    BOOL active = [state isEqualToString:JackStateStarting] || [state isEqualToString:JackStateRunning]
        || [state isEqualToString:JackStateFailed];
    if (active) [d setObject:[self jackdLogPath] forKey:JackStatusLogPath];
    if (jackd != nil || adoptedPid > 0) {
        [d setObject:(jackd != nil ? @"own" : @"adopted") forKey:JackStatusOwner];
        if (serverClock) [d setObject:serverClock forKey:JackStatusClockDevice];
    }
    if ([state isEqualToString:JackStateRunning]) {
        [d setObject:[NSNumber numberWithUnsignedInteger:serverRate] forKey:JackStatusSampleRate];
        [d setObject:[NSNumber numberWithUnsignedInteger:serverFrames] forKey:JackStatusBufferFrames];
        [d setObject:[[bridges allKeys] sortedArrayUsingSelector:@selector(compare:)]
              forKey:JackStatusBridges];
        if (drivenName) [d setObject:drivenName forKey:JackStatusDrivenDevice];
        if (routedOutputCard) [d setObject:routedOutputCard forKey:JackStatusRoutedOutputCard];
        if (routedInputCard) [d setObject:routedInputCard forKey:JackStatusRoutedInputCard];
        if (outputClient) {
            [d setObject:outputClient forKey:JackStatusOutputClient];
            [d setObject:[NSNumber numberWithBool:![outputClient isEqualToString:kSystemClient]]
                  forKey:JackStatusOutputBridged];
        }
        if (inputClient) [d setObject:inputClient forKey:JackStatusInputClient];
    }
    return d;
}

- (void)publishStatus
{
    NSDictionary *status = [self statusDictionary];
    if ([status isEqual:lastStatus]) return;
    ASSIGN(lastStatus, status);

    NSMutableDictionary *file = [NSMutableDictionary dictionaryWithDictionary:status];
    if (jackd != nil) {
        [file setObject:[NSNumber numberWithInt:(int)[jackd processIdentifier]] forKey:kStatusOwnPid];
        if (serverArguments) [file setObject:serverArguments forKey:kStatusOwnArguments];
    }
    NSString *path = [env statusPath];
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                   withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        NSLog(@"[JACK] cannot create the directory of %@: %@", path, dirError);
    } else if (![file writeToFile:path atomically:YES]) {
        NSLog(@"[JACK] cannot write %@", path);
    }
    [[NSNotificationCenter defaultCenter]
        postNotificationName:JackSupervisorStatusDidChangeNotification object:self];
}

+ (NSString *)menuTitleForStatus:(NSDictionary *)status
{
    NSString *s = [status objectForKey:JackStatusState];
    if (s == nil || [s isEqualToString:JackStateDisabled]) return nil;
    if ([s isEqualToString:JackStateUnavailable]) return @"JACK: unavailable";
    if ([s isEqualToString:JackStateStarting]) return @"JACK: starting...";
    if ([s isEqualToString:JackStateFailed]) return @"JACK: failed, see log";
    NSUInteger rate = [[status objectForKey:JackStatusSampleRate] unsignedIntegerValue];
    NSUInteger frames = [[status objectForKey:JackStatusBufferFrames] unsignedIntegerValue];
    NSString *khz = (rate % 1000 == 0)
        ? [NSString stringWithFormat:@"%lu", (unsigned long)(rate / 1000)]
        : [NSString stringWithFormat:@"%.1f", rate / 1000.0];
    return [NSString stringWithFormat:@"JACK: running, %@ kHz, %lu frames", khz, (unsigned long)frames];
}

#pragma mark ALSA devices

// "<card> - <PCM id>" like the ALSA backend names devices, so the name tells
// the PCMs of one card apart ("HDA Analog", "HDMI1"); the card's name alone
// when the PCM has no id of its own.
static NSString *pcmDisplayName(NSString *card, NSString *infoPath)
{
    NSString *info = [NSString stringWithContentsOfFile:infoPath encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *line in [info componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"id:"]) continue;
        NSString *pcm = [[line substringFromIndex:3]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // The kernel marks some ids with " (*)"; it is not part of the name.
        if ([pcm hasSuffix:@"(*)"]) {
            pcm = [[pcm substringToIndex:[pcm length] - 3]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        if ([pcm length] == 0 || [pcm isEqualToString:card]) return card;
        return [NSString stringWithFormat:@"%@ - %@", card, pcm];
    }
    return card;
}

+ (NSDictionary *)alsaDevicesAtRoot:(NSString *)root
{
    NSMutableArray *playback = [NSMutableArray array];
    NSMutableArray *capture = [NSMutableArray array];
    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
        playback, @"playback", capture, @"capture", nil];
    NSString *cards = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"cards"]
                                                encoding:NSUTF8StringEncoding error:NULL];
    NSFileManager *fm = [NSFileManager defaultManager];
    // " 0 [PCH            ]: HDA-Intel - HDA Intel PCH" plus an indented
    // second line with the long name.
    for (NSString *line in [cards componentsSeparatedByString:@"\n"]) {
        NSScanner *sc = [NSScanner scannerWithString:line];
        int index;
        NSString *cardId = nil;
        if (![sc scanInt:&index] || ![sc scanString:@"[" intoString:NULL]
            || ![sc scanUpToString:@"]" intoString:&cardId] || ![sc scanString:@"]" intoString:NULL]) {
            continue;
        }
        cardId = [cardId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *rest = [[line substringFromIndex:[sc scanLocation]]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([rest hasPrefix:@":"]) rest = [rest substringFromIndex:1];
        NSRange dash = [rest rangeOfString:@" - "];
        NSString *display = [(dash.location != NSNotFound ? [rest substringFromIndex:NSMaxRange(dash)] : rest)
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSString *dir = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"card%d", index]];
        NSMutableIndexSet *play = [NSMutableIndexSet indexSet];
        NSMutableIndexSet *cap = [NSMutableIndexSet indexSet];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![entry hasPrefix:@"pcm"] || [entry length] < 5) continue;
            unichar kind = [entry characterAtIndex:[entry length] - 1];
            NSString *number = [entry substringWithRange:NSMakeRange(3, [entry length] - 4)];
            NSInteger dev = [number integerValue];
            if (![[NSString stringWithFormat:@"%ld", (long)dev] isEqualToString:number]) continue;
            if (kind == 'p') [play addIndex:(NSUInteger)dev];
            else if (kind == 'c') [cap addIndex:(NSUInteger)dev];
        }
        NSMutableIndexSet *all = [NSMutableIndexSet indexSet];
        [all addIndexes:play];
        [all addIndexes:cap];
        BOOL several = [all count] > 1;
        NSIndexSet *sets[2] = { play, cap };
        NSMutableArray *lists[2] = { playback, capture };
        for (int pass = 0; pass < 2; pass++) {
            NSUInteger dev = [sets[pass] firstIndex];
            while (dev != NSNotFound) {
                NSString *name = several ? [NSString stringWithFormat:@"%@_%lu", cardId, (unsigned long)dev]
                                         : cardId;
                NSString *info = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"pcm%lu%c/info", (unsigned long)dev, pass == 0 ? 'p' : 'c']];
                [lists[pass] addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    name, JackDeviceCardId,
                    [NSNumber numberWithInt:index], JackDeviceCardIndex,
                    [NSString stringWithFormat:@"hw:CARD=%@,DEV=%lu", cardId, (unsigned long)dev], JackDeviceHW,
                    pass == 0 ? @"playback" : @"capture", JackDeviceDirection,
                    pcmDisplayName(display, info), JackDeviceDisplayName, nil]];
                dev = [sets[pass] indexGreaterThanIndex:dev];
            }
        }
    }
    return result;
}

#pragma mark jackd command lines

+ (NSString *)serverNameForJackdArguments:(NSArray *)argv
{
    // Server options come before the driver; after "-d alsa", -n means the
    // number of periods.
    NSUInteger count = [argv count];
    NSUInteger i = 0;
    if (count > 0 && ![[argv objectAtIndex:0] hasPrefix:@"-"]) i = 1;
    for (; i < count; i++) {
        NSString *a = [argv objectAtIndex:i];
        if ([a isEqualToString:@"-d"] || [a hasPrefix:@"--driver"] || ([a hasPrefix:@"-d"] && [a length] > 2))
            break;
        if (([a isEqualToString:@"-n"] || [a isEqualToString:@"--name"]) && i + 1 < count)
            return [argv objectAtIndex:i + 1];
        if ([a hasPrefix:@"--name="]) return [a substringFromIndex:7];
    }
    return @"default";
}

static NSString *argumentAfter(NSArray *argv, NSString *flag)
{
    NSUInteger i = [argv indexOfObject:flag];
    if (i == NSNotFound || i + 1 >= [argv count]) return nil;
    return [argv objectAtIndex:i + 1];
}

#pragma mark ~/.asoundrc

// Writes text over path by rename so ALSA never reads half a file; keeps
// the mode, follows a symlink to the file it names.  Empty text removes the
// file: that is what it was before the block was first written to it.
- (BOOL)writeAsoundrc:(NSString *)text existed:(BOOL)existed mode:(mode_t)mode
{
    NSString *path = [[env asoundrcPath] stringByResolvingSymlinksInPath];
    if ([text length] == 0) {
        if (unlink([path fileSystemRepresentation]) != 0 && errno != ENOENT) {
            NSLog(@"[JACK] cannot remove %@: %s", path, strerror(errno));
            return NO;
        }
        return YES;
    }
    NSString *tmp = [NSString stringWithFormat:@"%@.gershwin-jack.%d", path, (int)getpid()];
    int fd = open([tmp fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, existed ? mode : 0644);
    if (fd < 0) {
        NSLog(@"[JACK] cannot write %@: %s", tmp, strerror(errno));
        return NO;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *bytes = [data bytes];
    NSUInteger left = [data length];
    BOOL ok = YES;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            ok = NO;
            break;
        }
        bytes += n;
        left -= (NSUInteger)n;
    }
    // umask may have narrowed the mode open() was given.
    if (ok && existed && fchmod(fd, mode) != 0) ok = NO;
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0) ok = NO;
    if (!ok || rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
        NSLog(@"[JACK] cannot replace %@: %s", path, strerror(errno));
        unlink([tmp fileSystemRepresentation]);
        return NO;
    }
    return YES;
}

// block: the managed block the file must contain; nil: none.  Cheap when
// the file is as we left it and the block did not change.
- (void)setAsoundrcBlock:(NSString *)block
{
    BOOL want = (block != nil);
    NSString *path = [env asoundrcPath];
    NSArray *stamp = fileStamp(path);
    if (asoundrcStamp != nil && [stamp isEqual:asoundrcStamp]
        && (block == asoundrcBlock || [block isEqualToString:asoundrcBlock])) return;

    struct stat st;
    BOOL existed = (stat([path fileSystemRepresentation], &st) == 0);
    NSString *text = @"";
    if (existed) {
        NSError *readError = nil;
        text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
        if (text == nil) {
            [self logOnce:[NSString stringWithFormat:@"cannot read %@ as UTF-8: %@", path, readError]];
            return;
        }
    }
    NSString *problem = nil;
    NSString *updated = want ? [JackSupport asoundrcByApplyingJackBlock:block to:text error:&problem]
                             : [JackSupport asoundrcByRemovingJackBlockFrom:text error:&problem];
    if (updated == nil) {
        [self logOnce:[NSString stringWithFormat:@"%@ left alone: %@", path, problem]];
        return;
    }
    if (![updated isEqualToString:text]) {
        if (![self writeAsoundrc:updated existed:existed mode:existed ? (st.st_mode & 07777) : 0644])
            return;
        NSLog(@"[JACK] %@ the JACK block %@ %@", want ? @"wrote" : @"removed",
              want ? @"to" : @"from", path);
    }
    ASSIGN(asoundrcStamp, fileStamp(path));
    ASSIGN(asoundrcBlock, block);
}

- (void)removeAsoundrcBlock
{
    // Forget the stamp: the file must be looked at, whatever we wrote last.
    DESTROY(asoundrcStamp);
    [self setAsoundrcBlock:nil];
    DESTROY(asoundrcStamp);
}

#pragma mark Settings

- (BOOL)reloadSettingsIfChanged
{
    NSString *path = [env settingsPath];
    NSArray *stamp = fileStamp(path);
    if (settings != nil && [stamp isEqual:settingsStamp]) return NO;
    ASSIGN(settingsStamp, stamp);
    NSDictionary *fresh = [JackSupport settingsAtPath:path];
    settingsReadCount++;
    if ([fresh isEqual:settings]) return NO;
    NSDictionary *old = [settings retain];
    ASSIGN(settings, fresh);
    [self settingsChangedFrom:old];
    [old release];
    return YES;
}

// Called by the settings watch: a new selection is acted on at once rather
// than on the next timer tick.
- (void)settingsMayHaveChanged
{
    if (!started) return;
    if (![self reloadSettingsIfChanged]) return;
    if ([self useJack] && timer != nil) [self tick];
    else [self publishStatus];
}

- (void)settingsChangedFrom:(NSDictionary *)old
{
    // A change of the settings is a new chance: retry from scratch.
    fastUntil = [env now] + kFastTickWindow;
    failures = 0;
    gaveUp = NO;
    nextAttempt = 0;
    [bridgeFailures removeAllObjects];
    [loggedProblems removeAllObjects];

    if (![self useJack]) {
        [self shutDownJack];
        [self setState:JackStateDisabled message:nil];
        return;
    }
    if (![env isJackdInstalled]) {
        [self shutDownJack];
        [self setState:JackStateUnavailable message:@"jackd or libjack is not installed"];
        NSLog(@"[JACK] UseJack is on but jackd or libjack.so.0 is not installed");
        return;
    }
    [self ensureTimer];

    BOOL haveServer = (jackd != nil || adoptedPid > 0);
    if (!haveServer || old == nil || ![[old objectForKey:JackSettingUseJack] boolValue]) {
        if ([state isEqualToString:JackStateDisabled] || [state isEqualToString:JackStateUnavailable]
            || [state isEqualToString:JackStateFailed]) {
            [self setState:JackStateStarting message:nil];
        }
        return;
    }

    // A new device selection never restarts jackd: the next tick bridges
    // the device and moves the connections, without dropping any client.
    BOOL rateChanged = ![[old objectForKey:JackSettingSampleRate]
                           isEqual:[settings objectForKey:JackSettingSampleRate]];
    BOOL framesChanged = ![[old objectForKey:JackSettingBufferFrames]
                             isEqual:[settings objectForKey:JackSettingBufferFrames]];

    if (rateChanged) {
        if (jackd != nil) {
            NSLog(@"[JACK] sample rate changed: restarting jackd");
            [self stopServer];
            [self setState:JackStateStarting message:nil];
            return;
        }
        NSLog(@"[JACK] the sample rate change needs jackd (pid %d, not started by "
              @"Sound) to be restarted by whoever started it", (int)adoptedPid);
    }
    if (framesChanged && server == nil) server = [(id)[env openServer] retain];
    if (framesChanged && server != nil) {
        NSUInteger frames = [[settings objectForKey:JackSettingBufferFrames] unsignedIntegerValue];
        if ([server setBufferFrames:frames]) {
            NSLog(@"[JACK] buffer size set to %lu frames", (unsigned long)frames);
        } else {
            NSLog(@"[JACK] the server refused a buffer size of %lu frames", (unsigned long)frames);
        }
        // Setting the size activated the client; see -closeServerIfActivated.
        [self closeServer];
    }
}

#pragma mark Lifecycle

- (void)start
{
    if (started) return;
    started = YES;
    if (![env isPlatformSupported]) {
        // Not even a status file: nothing of JACK exists on this system.
        [self setState:JackStateUnavailable message:@"JACK is only supported on Linux"];
        return;
    }
    // Read before the first status write replaces it.
    ASSIGN(recordedOwn, [NSDictionary dictionaryWithContentsOfFile:[env statusPath]]);
    NSString *watchError = nil;
    __block JackSupervisor *me = self;    // -stop ends the watch before the supervisor goes
    if (![env watchSettingsWithBlock:^{ [me settingsMayHaveChanged]; } error:&watchError]) {
        NSLog(@"[JACK] cannot watch the Sound settings: %@", watchError);
    }
    [self reloadSettingsIfChanged];
    [self publishStatus];
    if ([self useJack] && [state isEqualToString:JackStateStarting]) [self tick];
}

- (void)stop
{
    [self stopPosting:YES];
}

- (void)stopPosting:(BOOL)post
{
    if (!started) return;
    [env stopWatchingSettings];
    [self shutDownJack];
    [self setState:JackStateDisabled message:nil];
    if (post) [self publishStatus];
    started = NO;
    DESTROY(settings);
    DESTROY(settingsStamp);
}

// Order matters: ALSA applications must never be left pointing at a server
// that is about to go away.
- (void)shutDownJack
{
    [self cancelTimer];
    [self removeAsoundrcBlock];
    [self stopAllBridges];
    [self stopServer];
}

- (void)closeServer
{
    if (server == nil) return;
    [server close];
    [(id)server release];
    server = nil;
}

// Forgets the server; kills it only when we started it.
- (void)stopServer
{
    [self removeAsoundrcBlock];
    [self stopAllBridges];
    [self closeServer];
    if (jackd != nil) {
        pid_t pid = [jackd processIdentifier];
        [env sendSignal:SIGTERM toProcess:-pid];
        NSTimeInterval deadline = [env now] + kJackdGrace;
        while ([jackd isRunning] && [env now] < deadline) [env sleepFor:0.05];
        if ([jackd isRunning]) {
            NSLog(@"[JACK] jackd (pid %d) ignored SIGTERM for %.0f s, killing it", (int)pid, kJackdGrace);
            [env sendSignal:SIGKILL toProcess:-pid];
            deadline = [env now] + 1.0;
            while ([jackd isRunning] && [env now] < deadline) [env sleepFor:0.05];
            if ([jackd isRunning]) NSLog(@"[JACK] jackd (pid %d) survived SIGKILL", (int)pid);
        }
        [(id)jackd release];
        jackd = nil;
    }
    adoptedPid = 0;
    DESTROY(serverArguments);
    DESTROY(serverClock);
    DESTROY(drivenName);
    DESTROY(routedOutputClient);
    DESTROY(routedInputClient);
    DESTROY(routedOutputCard);
    DESTROY(routedInputCard);
    DESTROY(outputClient);
    DESTROY(inputClient);
    serverRate = 0;
    serverFrames = 0;
}

#pragma mark Starting the server

- (void)recordFailure:(NSString *)why
{
    failures++;
    if (failures >= kMaxFailures) {
        gaveUp = YES;
        NSString *text = [NSString stringWithFormat:@"%@; gave up after %lu attempts (log: %@)",
                          why, (unsigned long)failures, [self jackdLogPath]];
        NSLog(@"[JACK] %@", text);
        [self setState:JackStateFailed message:text];
        // Nothing to do until the settings change, which the watch reports.
        [self cancelTimer];
        return;
    }
    NSTimeInterval delay = backoffAfter(failures);
    nextAttempt = [env now] + delay;
    NSLog(@"[JACK] %@; retrying in %.0f s (attempt %lu of %lu)", why, delay,
          (unsigned long)failures + 1, (unsigned long)kMaxFailures);
    [self setState:JackStateFailed message:[NSString stringWithFormat:@"%@; retrying", why]];
}

// The present device the user selected for a direction ("playback" or
// "capture"); *selection names the selection, present or not (nil: none).
- (NSDictionary *)selectedDevice:(NSString *)direction inDevices:(NSDictionary *)devices
                       selection:(NSString **)selection
{
    BOOL playback = [direction isEqualToString:@"playback"];
    return [JackSupport selectedDeviceInDevices:[devices objectForKey:direction]
                                       jackCard:[settings objectForKey:playback ? JackSettingOutputCard
                                                                                : JackSettingInputCard]
                                    alsaDefault:[settings objectForKey:playback ? JackSettingALSAOutput
                                                                                : JackSettingALSAInput]
                                      selection:selection];
}

// jackd runs on the selected output, so the common case needs no bridge;
// when that is unplugged, on the first card that can play.
- (NSString *)deviceForNewJackd
{
    NSDictionary *devices = [[self class] alsaDevicesAtRoot:[env alsaProcRoot]];
    NSDictionary *device = [self selectedDevice:@"playback" inDevices:devices selection:NULL];
    NSArray *playback = [devices objectForKey:@"playback"];
    if (device == nil && [playback count] > 0) device = [playback objectAtIndex:0];
    return [device objectForKey:JackDeviceHW];
}

// A jackd of this user for our server name, if one runs.
- (NSDictionary *)existingJackd
{
    NSString *name = [self effectiveServerName];
    for (NSDictionary *p in [env userProcessesNamed:[NSArray arrayWithObjects:@"jackd", @"jackdbus", nil]]) {
        if ([[[self class] serverNameForJackdArguments:[p objectForKey:@"argv"]] isEqualToString:name])
            return p;
    }
    return nil;
}

- (void)attemptStart
{
    NSDictionary *existing = [self existingJackd];
    if (existing != nil) {
        pid_t pid = [[existing objectForKey:@"pid"] intValue];
        NSArray *argv = [existing objectForKey:@"argv"];
        BOOL ours = [[recordedOwn objectForKey:kStatusOwnPid] intValue] == pid
            && [argv count] > 0
            && [[recordedOwn objectForKey:kStatusOwnArguments] isEqual:
                   [argv subarrayWithRange:NSMakeRange(1, [argv count] - 1)]];
        adoptedPid = pid;
        // Kept without the program name, like the arguments we launch with.
        ASSIGN(serverArguments, [argv count] > 0
               ? [argv subarrayWithRange:NSMakeRange(1, [argv count] - 1)] : argv);
        ASSIGN(serverClock, [JackSupport clockDeviceForJackdArguments:argv]);
        startedAt = [env now];
        if (ours) {
            NSLog(@"[JACK] jackd pid %d was started by an earlier Sound menu: taking it over", (int)pid);
        } else {
            NSLog(@"[JACK] using the jackd already running (pid %d); it is left running on stop", (int)pid);
        }
        [self setState:JackStateStarting message:nil];
        if (ours) [self takeOverPid:pid];
        return;
    }

    NSString *clock = [self deviceForNewJackd];
    if (clock == nil) {
        [self recordFailure:@"no ALSA playback device for jackd"];
        return;
    }
    NSMutableDictionary *jackdSettings = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        clock, JackdDevice,
        [settings objectForKey:JackSettingSampleRate], JackdSampleRate,
        [settings objectForKey:JackSettingBufferFrames], JackdBufferFrames, nil];
    if ([env serverName]) [jackdSettings setObject:[env serverName] forKey:JackdServerName];
    NSString *error = nil;
    NSArray *args = [JackSupport jackdArgumentsForSettings:jackdSettings error:&error];
    if (args == nil) {
        [self recordFailure:[NSString stringWithFormat:@"cannot build the jackd command line: %@", error]];
        return;
    }
    // No file size limit: jackd sizes its shared memory files with
    // ftruncate, which the limit would refuse.  Its log is cut in the tick.
    id<JackSupervisorProcess> p = [env launchExecutable:@"jackd" arguments:args
                                                logPath:[self jackdLogPath] fileSizeLimit:0 error:&error];
    if (p == nil) {
        [self recordFailure:[NSString stringWithFormat:@"cannot start jackd: %@", error]];
        return;
    }
    jackd = [(id)p retain];
    ASSIGN(serverArguments, args);
    ASSIGN(serverClock, clock);
    startedAt = [env now];
    NSLog(@"[JACK] started jackd (pid %d): jackd %@", (int)[p processIdentifier],
          [args componentsJoinedByString:@" "]);
    [self setState:JackStateStarting message:nil];
}

// An orphaned jackd of ours (Menu died) is treated as a child: it is
// killed on stop and restarted for settings changes.
- (void)takeOverPid:(pid_t)pid
{
    jackd = [[JackPidProcess alloc] initWithPid:pid environment:env];
    adoptedPid = 0;
}

- (BOOL)serverProcessAlive
{
    if (jackd != nil) return [jackd isRunning];
    if (adoptedPid > 0) {
        return [env isProcessAlive:adoptedPid named:@"jackd"]
            || [env isProcessAlive:adoptedPid named:@"jackdbus"];
    }
    return NO;
}

- (void)checkStarting
{
    if (![self serverProcessAlive]) {
        NSString *who = jackd != nil ? @"jackd exited while starting" : @"the running jackd went away";
        [self stopServer];
        [self recordFailure:who];
        return;
    }
    id<JackSupervisorServer> s = [env openServer];
    if (s != nil) {
        server = [(id)s retain];
        serverRate = [s sampleRate];
        serverFrames = [s bufferFrames];
        failures = 0;
        [self setState:JackStateRunning message:nil];
        NSLog(@"[JACK] server running: %lu Hz, %lu frames, clock device %@", (unsigned long)serverRate,
              (unsigned long)serverFrames, serverClock ? serverClock : @"(none)");
        [self adoptOrphanedBridges];
        [self supervise];
        return;
    }
    if ([env now] - startedAt >= kStartTimeout) {
        if (jackd != nil) {
            [self stopServer];
            [self recordFailure:[NSString stringWithFormat:@"jackd did not answer within %.0f s",
                                 kStartTimeout]];
        } else {
            // Not ours to kill; look again later.
            adoptedPid = 0;
            DESTROY(serverArguments);
            DESTROY(serverClock);
            [self recordFailure:@"the running jackd does not answer"];
        }
    }
}

#pragma mark The tick

- (void)tick
{
    if (!started) return;
    [self reloadSettingsIfChanged];
    if (![self useJack] || [state isEqualToString:JackStateUnavailable]) {
        [self publishStatus];
        return;
    }
    [self reapDyingBridges];
    BOOL haveServer = (jackd != nil || adoptedPid > 0);
    if (!haveServer) {
        if (!gaveUp && [env now] >= nextAttempt) {
            [self attemptStart];
            haveServer = (jackd != nil || adoptedPid > 0);
        }
    }
    if (haveServer) {
        if (server == nil && ![state isEqualToString:JackStateRunning]) {
            [self checkStarting];
        } else if (![self serverProcessAlive]) {
            NSLog(@"[JACK] jackd went away");
            BOOL own = (jackd != nil);
            [self stopServer];
            if (own) [self recordFailure:@"jackd exited"];
            else [self setState:JackStateStarting message:nil];
        } else {
            [self supervise];
        }
    }
    [self adjustTimer];
    [self publishStatus];
}

// One pass over a running server.
- (void)supervise
{
    if (server == nil) {
        server = [(id)[env openServer] retain];
        if (server == nil) {
            [self logOnce:@"the running jackd does not answer"];
            return;
        }
    }
    [self capLog:[self jackdLogPath] size:fileSize([self jackdLogPath])];
    // The buffer size can change under us (the pane, jack_bufsize).
    serverRate = [server sampleRate];
    serverFrames = [server bufferFrames];
    NSDictionary *devices = [[self class] alsaDevicesAtRoot:[env alsaProcRoot]];
    NSString *outSelection = nil;
    NSString *inSelection = nil;
    NSDictionary *outDevice = [self selectedDevice:@"playback" inDevices:devices selection:&outSelection];
    NSDictionary *inDevice = [self selectedDevice:@"capture" inDevices:devices selection:&inSelection];
    NSString *driven = nil;
    for (NSDictionary *d in [devices objectForKey:@"playback"]) {
        if ([JackSupport isDevice:d clockDevice:serverClock]) {
            driven = [d objectForKey:JackDeviceDisplayName];
            break;
        }
    }
    ASSIGN(drivenName, driven);
    // Routing first: a deselected bridge loses its applications to the new
    // device before it is stopped, not after.
    NSArray *ports = [self routeOutput:outDevice selection:outSelection input:inDevice selection:inSelection];
    [self superviseBridgesForOutput:outDevice input:inDevice];
    [self updateAsoundrcForPorts:ports];
}

// The block names the ports the applications are routed to, so a stream an
// ALSA application starts connects to ports that exist.
- (void)updateAsoundrcForPorts:(NSArray *)ports
{
    if (![env isALSAJackPluginInstalled]) {
        [self logOnce:@"the ALSA jack plugin (libasound_module_pcm_jack.so) is not installed: "
                      @"ALSA applications keep using the devices directly"];
        return;
    }
    if (ports == nil) {
        // Port list unreadable this tick: keep whatever block is in place.
        [self setAsoundrcBlock:asoundrcBlock ? asoundrcBlock : [JackSupport asoundrcJackBlock]];
        return;
    }
    // Bridges stopped in this tick still have ports; they must not be named.
    NSMutableArray *live = [NSMutableArray array];
    for (NSDictionary *p in ports) {
        NSString *client = [p objectForKey:@"client"];
        BOOL bridge = [client hasPrefix:@"gsout-"] || [client hasPrefix:@"gsin-"];
        if (!bridge || [bridges objectForKey:client] != nil) [live addObject:p];
    }
    [self setAsoundrcBlock:[JackSupport asoundrcJackBlockForPorts:live
                                                     outputClient:outputClient
                                                      inputClient:inputClient]];
}

#pragma mark Bridges

- (BOOL)bridgeAlive:(NSString *)name
{
    return [self handleAlive:[bridges objectForKey:name]];
}

- (pid_t)bridgePid:(NSString *)name
{
    id b = [bridges objectForKey:name];
    if ([b isKindOfClass:[NSNumber class]]) return [b intValue];
    return [(id<JackSupervisorProcess>)b processIdentifier];
}

// Bridges a crashed supervisor left behind keep their devices; taking them
// over avoids a gap in the sound.
- (void)adoptOrphanedBridges
{
    NSString *name = [self effectiveServerName];
    for (NSDictionary *p in [env userProcessesNamed:[NSArray arrayWithObjects:@"alsa_out", @"alsa_in", nil]]) {
        NSArray *argv = [p objectForKey:@"argv"];
        NSString *client = argumentAfter(argv, @"-j");
        if (![client hasPrefix:@"gsout-"] && ![client hasPrefix:@"gsin-"]) continue;
        NSString *bridgeServer = argumentAfter(argv, @"-S");
        if (![(bridgeServer ? bridgeServer : @"default") isEqualToString:name]) continue;
        if ([bridges objectForKey:client] != nil) continue;
        NSLog(@"[JACK] taking over bridge %@ (pid %@)", client, [p objectForKey:@"pid"]);
        [bridges setObject:[p objectForKey:@"pid"] forKey:client];
    }
}

- (BOOL)handleAlive:(id)handle
{
    if ([handle isKindOfClass:[NSNumber class]]) {
        pid_t pid = [handle intValue];
        return [env isProcessAlive:pid named:@"alsa_out"] || [env isProcessAlive:pid named:@"alsa_in"];
    }
    return [(id<JackSupervisorProcess>)handle isRunning];
}

- (void)terminateBridge:(NSString *)name
{
    pid_t pid = [self bridgePid:name];
    [env sendSignal:SIGTERM toProcess:pid];
    // The handle is kept until the child is gone: asking a child process
    // whether it runs is what reaps it.
    [dyingBridges setObject:[NSArray arrayWithObjects:
                                [NSNumber numberWithDouble:[env now] + kBridgeGrace],
                                [bridges objectForKey:name], nil]
                     forKey:[NSNumber numberWithInt:(int)pid]];
    [bridges removeObjectForKey:name];
    [bridgeHealth removeObjectForKey:name];
}

// A bridge that ignored SIGTERM is killed, without waiting in the tick.
- (void)reapDyingBridges
{
    for (NSNumber *pidNumber in [dyingBridges allKeys]) {
        pid_t pid = [pidNumber intValue];
        NSArray *entry = [dyingBridges objectForKey:pidNumber];
        if (![self handleAlive:[entry objectAtIndex:1]]) {
            [dyingBridges removeObjectForKey:pidNumber];
        } else if ([env now] >= [[entry objectAtIndex:0] doubleValue]) {
            NSLog(@"[JACK] bridge pid %d ignored SIGTERM, killing it", (int)pid);
            [env sendSignal:SIGKILL toProcess:pid];
            // Pushed out again so the handle reaps the killed child.
            [dyingBridges setObject:[NSArray arrayWithObjects:
                                        [NSNumber numberWithDouble:[env now] + 60.0],
                                        [entry objectAtIndex:1], nil]
                             forKey:pidNumber];
        }
    }
}

- (void)stopAllBridges
{
    if ([bridges count] == 0 && [dyingBridges count] == 0) return;
    for (NSString *name in [bridges allKeys]) {
        NSLog(@"[JACK] stopping bridge %@", name);
        [self terminateBridge:name];
    }
    // On the way out nobody reaps later, so wait for them here.
    NSTimeInterval deadline = [env now] + kBridgeGrace;
    while ([dyingBridges count] > 0) {
        [self reapDyingBridges];
        if ([dyingBridges count] == 0) break;
        if ([env now] >= deadline) {
            for (NSNumber *pid in [dyingBridges allKeys]) {
                NSLog(@"[JACK] bridge pid %@ ignored SIGTERM, killing it", pid);
                [env sendSignal:SIGKILL toProcess:[pid intValue]];
                [self handleAlive:[[dyingBridges objectForKey:pid] objectAtIndex:1]];
            }
            [dyingBridges removeAllObjects];
            break;
        }
        [env sleepFor:0.05];
    }
}

- (NSString *)bridgeLogPath:(NSString *)name
{
    return [[env logDirectory] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"jack-%@.log", name]];
}

// The children write with O_APPEND, so they go on at the new end.
- (unsigned long long)capLog:(NSString *)path size:(unsigned long long)size
{
    if (size <= kLogTruncateBytes) return size;
    if (truncate([path fileSystemRepresentation], 0) != 0) {
        [self logOnce:[NSString stringWithFormat:@"cannot truncate %@: %s", path, strerror(errno)]];
        return size;
    }
    NSLog(@"[JACK] %@ reached %llu KB, truncated", path, size / 1024);
    return 0;
}

// Card index and inode/device number of the device's PCM node: a USB device
// the kernel enumerates again gets new nodes (and maybe another index)
// while its card id, and so the bridge's name and argv, stay the same.
- (NSArray *)nodeIdentityOfDevice:(NSDictionary *)device
{
    NSNumber *index = [device objectForKey:JackDeviceCardIndex];
    NSString *hw = [device objectForKey:JackDeviceHW];
    NSRange r = [hw rangeOfString:@"DEV="];
    if (index == nil || r.location == NSNotFound) return nil;
    int dev = [[hw substringFromIndex:NSMaxRange(r)] intValue];
    char kind = [[device objectForKey:JackDeviceDirection] isEqualToString:@"capture"] ? 'c' : 'p';
    NSString *node = [[env alsaDevRoot] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"pcmC%dD%d%c", [index intValue], dev, kind]];
    struct stat st;
    // Not ctime: udev changes the ACLs of the nodes when the active session
    // changes, which is no reason to restart anything.
    if (stat([node fileSystemRepresentation], &st) != 0) return [NSArray arrayWithObject:index];
    return [NSArray arrayWithObjects:index,
        [NSNumber numberWithUnsignedLongLong:(unsigned long long)st.st_ino],
        [NSNumber numberWithUnsignedLongLong:(unsigned long long)st.st_rdev], nil];
}

- (void)recordHealthOfBridge:(NSString *)name device:(NSDictionary *)device
{
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    NSArray *identity = device ? [self nodeIdentityOfDevice:device] : nil;
    if (identity) [h setObject:identity forKey:@"identity"];
    [h setObject:[NSNumber numberWithDouble:[env cpuSecondsOfProcess:[self bridgePid:name]]] forKey:@"cpu"];
    [h setObject:[NSNumber numberWithDouble:[env now]] forKey:@"at"];
    [h setObject:[NSNumber numberWithUnsignedInteger:0] forKey:@"hot"];
    [h setObject:[NSNumber numberWithUnsignedLongLong:fileSize([self bridgeLogPath:name])] forKey:@"logSize"];
    [bridgeHealth setObject:h forKey:name];
}

- (void)checkHealthOfBridge:(NSString *)name device:(NSDictionary *)device
{
    NSMutableDictionary *h = [bridgeHealth objectForKey:name];
    if (h == nil) {
        // Taken over from an earlier run: measured from now on.
        [self recordHealthOfBridge:name device:device];
        return;
    }
    NSString *log = [self bridgeLogPath:name];
    NSTimeInterval now = [env now];
    NSTimeInterval elapsed = now - [[h objectForKey:@"at"] doubleValue];
    double cpu = [env cpuSecondsOfProcess:[self bridgePid:name]];
    double lastCPU = [[h objectForKey:@"cpu"] doubleValue];
    unsigned long long size = fileSize(log);
    unsigned long long lastSize = [[h objectForKey:@"logSize"] unsignedLongLongValue];
    NSUInteger hot = [[h objectForKey:@"hot"] unsignedIntegerValue];

    NSArray *identity = device ? [self nodeIdentityOfDevice:device] : nil;
    NSArray *known = [h objectForKey:@"identity"];
    if (identity != nil && known != nil && ![identity isEqual:known]) {
        // Not a failure of the bridge: started again right away.
        NSLog(@"[JACK] the device of bridge %@ was enumerated again, restarting the bridge", name);
        [self terminateBridge:name];
        return;
    }
    NSString *why = nil;
    if (elapsed > 0) {
        if (cpu >= 0 && lastCPU >= 0 && (cpu - lastCPU) / elapsed > kBridgeMaxCPU) hot++;
        else hot = 0;
        if (hot >= kBridgeHotTicks) {
            why = [NSString stringWithFormat:@"used %.0f%% CPU for %lu ticks", 100.0 * (cpu - lastCPU) / elapsed,
                   (unsigned long)hot];
        } else if (size > lastSize && (size - lastSize) / elapsed > kBridgeMaxLogRate) {
            why = [NSString stringWithFormat:@"log grew by %.0f KB/s", (size - lastSize) / elapsed / 1024.0];
        }
    }
    if (why != nil) {
        NSLog(@"[JACK] bridge %@ %@ (see %@), restarting it", name, why, log);
        [self capLog:log size:size];
        [self terminateBridge:name];
        [self recordBridgeFailure:name];
        return;
    }
    if (identity) [h setObject:identity forKey:@"identity"];
    [h setObject:[NSNumber numberWithDouble:cpu] forKey:@"cpu"];
    [h setObject:[NSNumber numberWithDouble:now] forKey:@"at"];
    [h setObject:[NSNumber numberWithUnsignedInteger:hot] forKey:@"hot"];
    [h setObject:[NSNumber numberWithUnsignedLongLong:[self capLog:log size:size]] forKey:@"logSize"];
}

- (BOOL)bridgeMayStart:(NSString *)name
{
    NSDictionary *f = [bridgeFailures objectForKey:name];
    if (f == nil) return YES;
    if ([[f objectForKey:@"count"] unsignedIntegerValue] >= kMaxFailures) return NO;
    return [env now] >= [[f objectForKey:@"next"] doubleValue];
}

- (void)recordBridgeFailure:(NSString *)name
{
    NSUInteger count = [[[bridgeFailures objectForKey:name] objectForKey:@"count"] unsignedIntegerValue] + 1;
    NSTimeInterval delay = backoffAfter(count);
    [bridgeFailures setObject:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInteger:count], @"count",
        [NSNumber numberWithDouble:[env now] + delay], @"next", nil] forKey:name];
    if (count >= kMaxFailures) {
        NSLog(@"[JACK] bridge %@ failed %lu times, giving up (log: %@)", name, (unsigned long)count,
              [self bridgeLogPath:name]);
    } else {
        NSLog(@"[JACK] bridge %@ exited; restarting it in %.0f s", name, delay);
    }
}

// Only what is selected is bridged: at most one alsa_out and one alsa_in,
// none when the selection is the device jackd runs on.
- (void)superviseBridgesForOutput:(NSDictionary *)outDevice input:(NSDictionary *)inDevice
{
    NSMutableDictionary *wantedDevices = [NSMutableDictionary dictionary];
    if (outDevice) [wantedDevices setObject:outDevice forKey:
        [JackSupport bridgeClientNameForCardId:[outDevice objectForKey:JackDeviceCardId] direction:@"playback"]];
    if (inDevice) [wantedDevices setObject:inDevice forKey:
        [JackSupport bridgeClientNameForCardId:[inDevice objectForKey:JackDeviceCardId] direction:@"capture"]];
    for (NSString *name in [bridges allKeys]) {
        if (![self bridgeAlive:name]) {
            [bridges removeObjectForKey:name];
            [bridgeHealth removeObjectForKey:name];
            [self recordBridgeFailure:name];
        } else {
            [self checkHealthOfBridge:name device:[wantedDevices objectForKey:name]];
        }
    }
    NSDictionary *plan = [JackSupport bridgePlanForPlaybackDevices:outDevice ? [NSArray arrayWithObject:outDevice]
                                                                             : [NSArray array]
                                                    captureDevices:inDevice ? [NSArray arrayWithObject:inDevice]
                                                                            : [NSArray array]
                                                    runningBridges:[bridges allKeys]
                                                       clockDevice:serverClock
                                                        sampleRate:serverRate
                                                      bufferFrames:serverFrames
                                                           periods:kBridgePeriods
                                                        serverName:[env serverName]];
    for (NSString *error in [plan objectForKey:@"errors"]) [self logOnce:error];
    for (NSString *name in [plan objectForKey:@"stop"]) {
        NSLog(@"[JACK] bridge %@ is no longer needed, stopping it", name);
        [self terminateBridge:name];
        [bridgeFailures removeObjectForKey:name];
    }
    for (NSDictionary *start in [plan objectForKey:@"start"]) {
        NSString *name = [start objectForKey:@"name"];
        if (![self bridgeMayStart:name]) continue;
        if (lastBridgeStart > 0 && [env now] < lastBridgeStart + kBridgeStagger) break;
        lastBridgeStart = [env now];
        NSString *error = nil;
        NSString *log = [self bridgeLogPath:name];
        id<JackSupervisorProcess> p = [env launchExecutable:[start objectForKey:@"executable"]
                                                  arguments:[start objectForKey:@"arguments"]
                                                    logPath:log fileSizeLimit:kBridgeFileSizeLimit
                                                      error:&error];
        if (p == nil) {
            NSLog(@"[JACK] cannot start bridge %@: %@", name, error);
            [self recordBridgeFailure:name];
            continue;
        }
        NSLog(@"[JACK] started bridge %@ for %@ (pid %d)", name, [start objectForKey:@"hw"],
              (int)[p processIdentifier]);
        [bridges setObject:p forKey:name];
        [self recordHealthOfBridge:name device:[wantedDevices objectForKey:name]];
        fastUntil = [env now] + kFastTickWindow;
    }
}

#pragma mark Patchbay

// Whether client has the ports the applications connect to: playback
// ports are JACK inputs, capture ports JACK outputs.
static BOOL clientHasPorts(NSArray *ports, NSString *client, BOOL playback)
{
    for (NSDictionary *p in ports) {
        if (![[p objectForKey:@"client"] isEqualToString:client]) continue;
        if ([[p objectForKey:playback ? @"isInput" : @"isOutput"] boolValue]) return YES;
    }
    return NO;
}

// The JACK client of the selected device of one direction.
- (NSString *)clientForDevice:(NSDictionary *)device selection:(NSString *)selection
                    direction:(NSString *)direction problem:(NSString **)problem
{
    if (device == nil) {
        // Unplugged: the setting stays, so the device is used again once it is back.
        if (selection != nil) {
            *problem = [NSString stringWithFormat:@"%@ device %@ is not present, using %@",
                        [direction isEqualToString:@"playback"] ? @"output" : @"input", selection,
                        drivenName ? drivenName : @"the device JACK runs on"];
        }
        return kSystemClient;
    }
    if ([JackSupport isDevice:device clockDevice:serverClock]) return kSystemClient;
    return [JackSupport bridgeClientNameForCardId:[device objectForKey:JackDeviceCardId] direction:direction];
}

// Returns the port list it worked on, nil when it could not be read.
- (NSArray *)routeOutput:(NSDictionary *)outDevice selection:(NSString *)outSelection
                   input:(NSDictionary *)inDevice selection:(NSString *)inSelection
{
    NSString *outProblem = nil;
    NSString *inProblem = nil;
    NSString *out = [self clientForDevice:outDevice selection:outSelection direction:@"playback"
                                  problem:&outProblem];
    NSString *in = [self clientForDevice:inDevice selection:inSelection direction:@"capture"
                                 problem:&inProblem];
    ASSIGN(outputClient, out);
    ASSIGN(inputClient, in);
    NSString *note = outProblem ? outProblem : inProblem;
    if (outProblem && inProblem) note = [NSString stringWithFormat:@"%@; %@", outProblem, inProblem];
    ASSIGN(message, note);

    NSArray *ports = [server allPorts];
    if (ports == nil) {
        [self logOnce:@"cannot read the JACK ports"];
        return nil;
    }
    // The pane waits for these to know the sound really goes to the new
    // device: a side counts as routed once its client's ports exist, which is
    // when the plan below connects the applications to them.
    if (clientHasPorts(ports, out, YES)) {
        ASSIGN(routedOutputClient, out);
        ASSIGN(routedOutputCard, outDevice && ![out isEqualToString:kSystemClient]
               ? [outDevice objectForKey:JackDeviceCardId] : @"clock");
    }
    if (clientHasPorts(ports, in, NO)) {
        ASSIGN(routedInputClient, in);
        ASSIGN(routedInputCard, inDevice && ![in isEqualToString:kSystemClient]
               ? [inDevice objectForKey:JackDeviceCardId] : @"clock");
    }
    NSDictionary *plan = [JackSupport patchbayPlanForPorts:ports outputClient:out inputClient:in];
    NSArray *disconnect = [plan objectForKey:@"disconnect"];
    NSArray *connect = [plan objectForKey:@"connect"];
    if ([disconnect count] == 0 && [connect count] == 0) return ports;
    for (NSArray *op in disconnect) {
        if (![server disconnect:[op objectAtIndex:0] from:[op objectAtIndex:1]])
            NSLog(@"[JACK] cannot disconnect %@ from %@", [op objectAtIndex:0], [op objectAtIndex:1]);
    }
    for (NSArray *op in connect) {
        if (![server connect:[op objectAtIndex:0] to:[op objectAtIndex:1]])
            NSLog(@"[JACK] cannot connect %@ to %@", [op objectAtIndex:0], [op objectAtIndex:1]);
    }
    // Connecting activated the client, which costs a wakeup per period while
    // it stays open; the next tick opens a fresh, passive one.
    [self closeServer];
    return ports;
}

@end
