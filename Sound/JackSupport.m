/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "JackSupport.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#ifdef __linux__
#include <dlfcn.h>
#include <pthread.h>
#endif

NSString * const JackSettingUseJack = @"UseJack";
NSString * const JackSettingBufferFrames = @"JackBufferFrames";
NSString * const JackSettingSampleRate = @"JackSampleRate";
NSString * const JackSettingOutputCard = @"JackOutputCard";
NSString * const JackSettingInputCard = @"JackInputCard";
NSString * const JackSettingALSAOutput = @"defaultOutput";
NSString * const JackSettingALSAInput = @"defaultInput";

NSString * const JackClientName = @"gershwin-sound";

NSString * const JackdDevice = @"device";
NSString * const JackdSampleRate = @"rate";
NSString * const JackdBufferFrames = @"frames";
NSString * const JackdPeriods = @"periods";
NSString * const JackdServerName = @"serverName";

NSString * const JackDeviceCardId = @"cardId";
NSString * const JackDeviceCardIndex = @"cardIndex";
NSString * const JackDeviceHW = @"hw";
NSString * const JackDeviceDirection = @"direction";
NSString * const JackDeviceDisplayName = @"displayName";

static NSString * const kSystemClient = @"system";
static NSString * const kOutBridgePrefix = @"gsout-";
static NSString * const kInBridgePrefix = @"gsin-";
static NSString * const kBlockBegin = @"# BEGIN gershwin jack\n";

#pragma mark - Validation

static BOOL charIn(unichar c, const char *extra)
{
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return YES;
    for (; extra && *extra; extra++) {
        if (c == (unichar)*extra) return YES;
    }
    return NO;
}

static BOOL allCharsIn(NSString *s, const char *extra, NSUInteger maxLen)
{
    NSUInteger n = [s length];
    if (n == 0 || n > maxLen) return NO;
    for (NSUInteger i = 0; i < n; i++) {
        if (!charIn([s characterAtIndex:i], extra)) return NO;
    }
    // A leading '-' would turn the value into an option of the program it is
    // handed to.
    return [s characterAtIndex:0] != '-';
}

// ALSA device names as jackd and alsa_out take them on their command lines:
// no spaces, quotes, shell characters or leading dash.
static BOOL validDeviceName(NSString *s)
{
    return allCharsIn(s, "_:,.=-", 128);
}

// Card ids come from /proc/asound/cards plus "_<device>".
static BOOL validCardId(NSString *s)
{
    return allCharsIn(s, "_.-", 64);
}

static BOOL validServerName(NSString *s)
{
    return allCharsIn(s, "_.-", 32);
}

static BOOL validFrames(NSInteger f)
{
    // jackd insists on a power of two.
    return f >= 16 && f <= 8192 && (f & (f - 1)) == 0;
}

static BOOL validRate(NSInteger r) { return r >= 8000 && r <= 192000; }
static BOOL validPeriods(NSInteger p) { return p >= 2 && p <= 16; }

// A settings value that may be an NSNumber or a numeric string.
static BOOL integerFrom(id value, NSInteger *out)
{
    if ([value isKindOfClass:[NSNumber class]]) {
        *out = [value integerValue];
        return YES;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        NSInteger v = 0;
        if ([scanner scanInteger:&v] && [scanner isAtEnd]) {
            *out = v;
            return YES;
        }
    }
    return NO;
}

// Reads an optional integer setting: absent gives the default, present but
// unusable fails.
static BOOL optionalInteger(NSDictionary *d, NSString *key, NSInteger def,
                            NSInteger *out)
{
    id value = [d objectForKey:key];
    if (value == nil) {
        *out = def;
        return YES;
    }
    return integerFrom(value, out);
}

#pragma mark - libjack loader and JackConnection

#ifdef __linux__

typedef void jack_client_t;
typedef void jack_port_t;
typedef uint32_t jack_nframes_t;

enum {
    kJackNoStartServer = 0x01,
    kJackServerName = 0x04
};

// JackPortFlags
enum {
    kJackPortIsInput = 0x1,
    kJackPortIsOutput = 0x2,
    kJackPortIsPhysical = 0x4
};

#define GS_JACK_AUDIO_TYPE "32 bit float mono audio"

typedef struct {
    jack_client_t *(*client_open)(const char *, int, int *, ...);
    int (*client_close)(jack_client_t *);
    const char **(*get_ports)(jack_client_t *, const char *, const char *, unsigned long);
    jack_port_t *(*port_by_name)(jack_client_t *, const char *);
    int (*port_flags)(const jack_port_t *);
    const char *(*port_type)(const jack_port_t *);
    const char **(*port_get_all_connections)(const jack_client_t *, const jack_port_t *);
    int (*connect)(jack_client_t *, const char *, const char *);
    int (*disconnect)(jack_client_t *, const char *, const char *);
    jack_nframes_t (*get_sample_rate)(jack_client_t *);
    jack_nframes_t (*get_buffer_size)(jack_client_t *);
    int (*set_buffer_size)(jack_client_t *, jack_nframes_t);
    void (*jfree)(void *);
    int (*activate)(jack_client_t *);
    int (*deactivate)(jack_client_t *);
    int (*set_process_callback)(jack_client_t *, int (*)(jack_nframes_t, void *), void *);
    jack_port_t *(*port_register)(jack_client_t *, const char *, const char *,
                                  unsigned long, unsigned long);
} JackAPI;

static JackAPI jackAPI;
static BOOL jackAPILoaded = NO;
static pthread_once_t jackLoadOnce = PTHREAD_ONCE_INIT;

static void quietJackLog(const char *message) { (void)message; }

static void loadJackAPI(void)
{
    void *lib = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) return;

    JackAPI api;
#define LOAD(field, symbol) \
    do { *(void **)&api.field = dlsym(lib, symbol); \
         if (api.field == NULL) { dlclose(lib); return; } } while (0)
    LOAD(client_open, "jack_client_open");
    LOAD(client_close, "jack_client_close");
    LOAD(get_ports, "jack_get_ports");
    LOAD(port_by_name, "jack_port_by_name");
    LOAD(port_flags, "jack_port_flags");
    LOAD(port_type, "jack_port_type");
    LOAD(port_get_all_connections, "jack_port_get_all_connections");
    LOAD(connect, "jack_connect");
    LOAD(disconnect, "jack_disconnect");
    LOAD(get_sample_rate, "jack_get_sample_rate");
    LOAD(get_buffer_size, "jack_get_buffer_size");
    LOAD(set_buffer_size, "jack_set_buffer_size");
    LOAD(jfree, "jack_free");
    LOAD(activate, "jack_activate");
    LOAD(deactivate, "jack_deactivate");
    LOAD(set_process_callback, "jack_set_process_callback");
    LOAD(port_register, "jack_port_register");
#undef LOAD

    // libjack prints "Cannot connect to server socket" and the like to
    // stderr on every failed probe; probing for a server is a normal event
    // here, so nothing is logged (the return codes carry the failure).
    void (*setError)(void (*)(const char *)) = dlsym(lib, "jack_set_error_function");
    void (*setInfo)(void (*)(const char *)) = dlsym(lib, "jack_set_info_function");
    if (setError) setError(quietJackLog);
    if (setInfo) setInfo(quietJackLog);

    jackAPI = api;
    jackAPILoaded = YES;
}

static BOOL ensureJackAPI(void)
{
    pthread_once(&jackLoadOnce, loadJackAPI);
    return jackAPILoaded;
}

// Activation is only needed so the server accepts connect/disconnect and
// buffer size requests from this client; nothing is processed.
static int emptyProcess(jack_nframes_t nframes, void *arg)
{
    (void)nframes;
    (void)arg;
    return 0;
}

@implementation JackConnection

+ (BOOL)isLibraryAvailable
{
    return ensureJackAPI();
}

+ (JackConnection *)openWithServerName:(NSString *)serverName
{
    return [self openWithServerName:serverName clientName:JackClientName];
}

+ (JackConnection *)openWithServerName:(NSString *)serverName
                            clientName:(NSString *)clientName
{
    if (!ensureJackAPI()) return nil;
    // A probe must never start a jackd of its own.
    int options = kJackNoStartServer;
    if (serverName != nil) options |= kJackServerName;
    int status = 0;
    jack_client_t *c = jackAPI.client_open([clientName UTF8String], options, &status,
                                           [serverName UTF8String]);
    if (c == NULL) return nil;
    JackConnection *connection = [[[JackConnection alloc] init] autorelease];
    connection->client = c;
    return connection;
}

- (void)dealloc
{
    [self close];
    [super dealloc];
}

- (BOOL)isOpen
{
    @synchronized (self) {
        return client != NULL;
    }
}

- (BOOL)activateLocked
{
    if (client == NULL) return NO;
    if (activated) return YES;
    jackAPI.set_process_callback(client, emptyProcess, NULL);
    activated = (jackAPI.activate(client) == 0);
    return activated;
}

- (NSUInteger)sampleRate
{
    @synchronized (self) {
        return client ? jackAPI.get_sample_rate(client) : 0;
    }
}

- (NSUInteger)bufferFrames
{
    @synchronized (self) {
        return client ? jackAPI.get_buffer_size(client) : 0;
    }
}

- (BOOL)setBufferFrames:(NSUInteger)frames
{
    @synchronized (self) {
        if (![self activateLocked]) return NO;
        return jackAPI.set_buffer_size(client, (jack_nframes_t)frames) == 0;
    }
}

- (NSArray *)allPorts
{
    @synchronized (self) {
        if (client == NULL) return nil;
        NSMutableArray *result = [NSMutableArray array];
        const char **names = jackAPI.get_ports(client, NULL, GS_JACK_AUDIO_TYPE, 0);
        if (names == NULL) return result;
        for (int i = 0; names[i] != NULL; i++) {
            jack_port_t *port = jackAPI.port_by_name(client, names[i]);
            if (port == NULL) continue;     // vanished between the two calls
            int flags = jackAPI.port_flags(port);
            NSString *name = [NSString stringWithUTF8String:names[i]];
            if (name == nil) continue;
            NSRange colon = [name rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSMutableArray *connections = [NSMutableArray array];
            const char **conns = jackAPI.port_get_all_connections(client, port);
            if (conns != NULL) {
                for (int j = 0; conns[j] != NULL; j++) {
                    NSString *c = [NSString stringWithUTF8String:conns[j]];
                    if (c != nil) [connections addObject:c];
                }
                jackAPI.jfree(conns);
            }
            [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                name, @"name",
                [name substringToIndex:colon.location], @"client",
                [NSNumber numberWithInt:flags], @"flags",
                [NSNumber numberWithBool:(flags & kJackPortIsInput) != 0], @"isInput",
                [NSNumber numberWithBool:(flags & kJackPortIsOutput) != 0], @"isOutput",
                [NSNumber numberWithBool:(flags & kJackPortIsPhysical) != 0], @"isPhysical",
                connections, @"connections", nil]];
        }
        jackAPI.jfree(names);
        return result;
    }
}

- (BOOL)connect:(NSString *)source to:(NSString *)destination
{
    @synchronized (self) {
        if (![self activateLocked]) return NO;
        int rc = jackAPI.connect(client, [source UTF8String], [destination UTF8String]);
        // EEXIST (17): already connected is the state we want.
        return rc == 0 || rc == 17;
    }
}

- (BOOL)disconnect:(NSString *)source from:(NSString *)destination
{
    @synchronized (self) {
        if (![self activateLocked]) return NO;
        return jackAPI.disconnect(client, [source UTF8String], [destination UTF8String]) == 0;
    }
}

- (BOOL)registerAudioPortNamed:(NSString *)name flags:(unsigned long)flags
{
    @synchronized (self) {
        if (client == NULL) return NO;
        if (jackAPI.port_register(client, [name UTF8String], GS_JACK_AUDIO_TYPE,
                                  flags, 0) == NULL) {
            return NO;
        }
        return [self activateLocked];
    }
}

- (void)close
{
    @synchronized (self) {
        if (client == NULL) return;
        if (activated) jackAPI.deactivate(client);
        jackAPI.client_close(client);
        client = NULL;
        activated = NO;
    }
}

@end

#else /* !__linux__ */

// JACK support is Linux-only; elsewhere every probe reports "not available".
@implementation JackConnection
+ (BOOL)isLibraryAvailable { return NO; }
+ (JackConnection *)openWithServerName:(NSString *)serverName { return nil; }
+ (JackConnection *)openWithServerName:(NSString *)serverName
                            clientName:(NSString *)clientName { return nil; }
- (BOOL)isOpen { return NO; }
- (NSUInteger)sampleRate { return 0; }
- (NSUInteger)bufferFrames { return 0; }
- (BOOL)setBufferFrames:(NSUInteger)frames { return NO; }
- (NSArray *)allPorts { return nil; }
- (BOOL)connect:(NSString *)source to:(NSString *)destination { return NO; }
- (BOOL)disconnect:(NSString *)source from:(NSString *)destination { return NO; }
- (BOOL)registerAudioPortNamed:(NSString *)name flags:(unsigned long)flags { return NO; }
- (void)close { }
@end

#endif

#pragma mark - Planner helpers

static NSComparisonResult comparePortNames(id a, id b)
{
    return [a compare:b options:NSNumericSearch];
}

static BOOL isDeviceClient(NSString *client)
{
    return [client isEqualToString:kSystemClient]
        || [client hasPrefix:kOutBridgePrefix]
        || [client hasPrefix:kInBridgePrefix];
}

// gershwin-sound-01 is what JACK makes of a second client of that name.
static BOOL isOwnClient(NSString *client)
{
    return [client hasPrefix:JackClientName];
}

static BOOL portFlag(NSDictionary *port, NSString *key)
{
    return [[port objectForKey:key] boolValue];
}

// Application ports in one direction, grouped by client, each group in
// port-number order.  Devices, bridges and our own client are not
// applications.
static NSArray *applicationGroups(NSArray *ports, BOOL outputs)
{
    NSMutableDictionary *byClient = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *port in ports) {
        NSString *client = [port objectForKey:@"client"];
        if (portFlag(port, outputs ? @"isOutput" : @"isInput") == NO) continue;
        if (portFlag(port, @"isPhysical") || isDeviceClient(client) || isOwnClient(client))
            continue;
        NSMutableArray *group = [byClient objectForKey:client];
        if (group == nil) {
            group = [NSMutableArray array];
            [byClient setObject:group forKey:client];
            [order addObject:client];
        }
        [group addObject:port];
    }
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *client in [order sortedArrayUsingSelector:@selector(compare:)]) {
        [groups addObject:[[byClient objectForKey:client]
            sortedArrayUsingComparator:^NSComparisonResult(id x, id y) {
                return comparePortNames([x objectForKey:@"name"], [y objectForKey:@"name"]);
            }]];
    }
    return groups;
}

static NSArray *portNamesOfClient(NSArray *ports, NSString *client, BOOL outputs)
{
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *port in ports) {
        if (![[port objectForKey:@"client"] isEqualToString:client]) continue;
        if (portFlag(port, outputs ? @"isOutput" : @"isInput") == NO) continue;
        [names addObject:[port objectForKey:@"name"]];
    }
    return [names sortedArrayUsingFunction:
        (NSInteger (*)(id, id, void *))comparePortNames context:NULL];
}

// Names of all ports of devices (the system client and bridges) in one
// direction, whichever device is selected.
static NSSet *devicePortNames(NSArray *ports, BOOL outputs)
{
    NSMutableSet *set = [NSMutableSet set];
    for (NSDictionary *port in ports) {
        if (!isDeviceClient([port objectForKey:@"client"])) continue;
        if (portFlag(port, outputs ? @"isOutput" : @"isInput") == NO) continue;
        [set addObject:[port objectForKey:@"name"]];
    }
    return set;
}

// One side of the patchbay.  A playback side routes application output
// ports (sources) to the selected device's input ports; a capture side routes
// the selected device's output ports to application input ports.  Both are
// the same walk with the roles of "application" and "device" swapped.
static void planSide(NSArray *ports, NSString *deviceClient, BOOL playback,
                     NSMutableArray *connect, NSMutableArray *disconnect,
                     NSMutableArray *problems)
{
    NSString *what = playback ? @"output" : @"input";
    if (deviceClient == nil) {
        [problems addObject:[NSString stringWithFormat:@"no %@ device selected", what]];
        return;
    }
    // The device's side facing the applications: playback ports are JACK
    // inputs, capture ports JACK outputs.
    NSArray *devicePorts = portNamesOfClient(ports, deviceClient, !playback);
    if ([devicePorts count] == 0) {
        [problems addObject:[NSString stringWithFormat:
            @"%@ device '%@' is not present", what, deviceClient]];
        return;
    }
    NSSet *allDevicePorts = devicePortNames(ports, !playback);

    for (NSArray *group in applicationGroups(ports, playback)) {
        NSUInteger n = [group count];
        NSUInteger m = [devicePorts count];
        NSMutableSet *wanted = [NSMutableSet set];
        NSMutableArray *wantedPairs = [NSMutableArray array];
        for (NSUInteger i = 0; i < n; i++) {
            NSString *appPort = [[group objectAtIndex:i] objectForKey:@"name"];
            NSMutableArray *targets = [NSMutableArray array];
            if (playback) {
                // A mono source feeds every device port.
                if (n == 1) [targets addObjectsFromArray:devicePorts];
                else if (i < m) [targets addObject:[devicePorts objectAtIndex:i]];
            } else {
                // A mono device feeds every application port.
                if (m == 1) [targets addObject:[devicePorts objectAtIndex:0]];
                else if (i < m) [targets addObject:[devicePorts objectAtIndex:i]];
            }
            for (NSString *target in targets) {
                NSArray *pair = playback ? [NSArray arrayWithObjects:appPort, target, nil]
                                         : [NSArray arrayWithObjects:target, appPort, nil];
                [wantedPairs addObject:pair];
                [wanted addObject:[NSString stringWithFormat:@"%@>%@",
                    [pair objectAtIndex:0], [pair objectAtIndex:1]]];
            }
        }
        // Anything the application has to a device that is not wanted goes;
        // connections to other applications are not ours to touch.
        NSMutableSet *present = [NSMutableSet set];
        for (NSDictionary *p in group) {
            NSString *appPort = [p objectForKey:@"name"];
            for (NSString *other in [p objectForKey:@"connections"]) {
                if (![allDevicePorts containsObject:other]) continue;
                NSString *key = playback
                    ? [NSString stringWithFormat:@"%@>%@", appPort, other]
                    : [NSString stringWithFormat:@"%@>%@", other, appPort];
                if ([wanted containsObject:key]) {
                    [present addObject:key];
                } else {
                    [disconnect addObject:playback
                        ? [NSArray arrayWithObjects:appPort, other, nil]
                        : [NSArray arrayWithObjects:other, appPort, nil]];
                }
            }
        }
        for (NSArray *pair in wantedPairs) {
            NSString *key = [NSString stringWithFormat:@"%@>%@",
                [pair objectAtIndex:0], [pair objectAtIndex:1]];
            if (![present containsObject:key]) [connect addObject:pair];
        }
    }
}

// "hw:CARD=PCH,DEV=0", "hw:1", "plughw:PCH,0" -> card token and device number.
static void parseHW(NSString *hw, NSString **card, NSString **dev)
{
    *card = nil;
    *dev = nil;
    NSRange colon = [hw rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        NSMutableArray *bare = [NSMutableArray array];
        for (NSString *part in [[hw substringFromIndex:colon.location + 1]
                                   componentsSeparatedByString:@","]) {
            if ([part hasPrefix:@"CARD="]) *card = [part substringFromIndex:5];
            else if ([part hasPrefix:@"DEV="]) *dev = [part substringFromIndex:4];
            else if ([part length] > 0) [bare addObject:part];
        }
        // "hw:card,dev": the bare parts fill whatever the keyed ones left open.
        if (*card == nil && [bare count] > 0) {
            *card = [bare objectAtIndex:0];
            [bare removeObjectAtIndex:0];
        }
        if (*dev == nil && [bare count] > 0) *dev = [bare objectAtIndex:0];
    }
    if (*dev == nil) *dev = @"0";
}

static NSString *sanitizedClientSuffix(NSString *cardId)
{
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < [cardId length]; i++) {
        unichar c = [cardId characterAtIndex:i];
        if (charIn(c, "_-")) [out appendFormat:@"%C", c];
        else [out appendString:@"_"];
    }
    return out;
}

static BOOL deviceIsClock(NSDictionary *device, NSString *clockCard, NSString *clockDev)
{
    if (clockCard == nil) return NO;
    NSString *card = nil;
    NSString *dev = nil;
    parseHW([device objectForKey:JackDeviceHW], &card, &dev);
    if (![dev isEqualToString:clockDev]) return NO;
    NSString *cardId = [device objectForKey:JackDeviceCardId];
    NSNumber *index = [device objectForKey:JackDeviceCardIndex];
    return [clockCard isEqualToString:cardId]
        || (card != nil && [clockCard isEqualToString:card])
        || (index != nil && [clockCard isEqualToString:[index stringValue]]);
}

#pragma mark - JackSupport

@implementation JackSupport

#pragma mark Detection

+ (NSArray *)jackdProcessesInTable:(NSArray *)table forUID:(uid_t)uid
{
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *entry in table) {
        NSString *comm = [entry objectForKey:@"comm"];
        if (![comm isEqualToString:@"jackd"] && ![comm isEqualToString:@"jackdbus"]) continue;
        if ([[entry objectForKey:@"uid"] unsignedIntValue] != uid) continue;
        [result addObject:entry];
    }
    return result;
}

+ (NSArray *)jackdProcessIDsInTable:(NSArray *)table forUID:(uid_t)uid
{
    NSMutableArray *pids = [NSMutableArray array];
    for (NSDictionary *entry in [self jackdProcessesInTable:table forUID:uid]) {
        [pids addObject:[entry objectForKey:@"pid"]];
    }
    return pids;
}

#ifdef __linux__
static NSString *procRead(NSString *path, NSUInteger limit, NSData **raw)
{
    int fd = open([path fileSystemRepresentation], O_RDONLY);
    if (fd < 0) return nil;
    NSMutableData *data = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0 && [data length] < limit) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    if (raw) *raw = data;
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}
#endif

// The comm filter keeps the scan cheap: only candidates have their command
// line read.
+ (NSArray *)processTableMatching:(BOOL (^)(NSString *comm))wanted
{
    NSMutableArray *table = [NSMutableArray array];
#ifdef __linux__
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:@"/proc" error:NULL]) {
        int pid = [name intValue];
        if (pid <= 0 || ![[NSString stringWithFormat:@"%d", pid] isEqualToString:name]) continue;
        NSString *dir = [@"/proc" stringByAppendingPathComponent:name];
        NSString *comm = procRead([dir stringByAppendingPathComponent:@"comm"], 256, NULL);
        comm = [comm stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([comm length] == 0 || !wanted(comm)) continue;
        struct stat st;
        if (stat([dir fileSystemRepresentation], &st) != 0) continue;
        NSData *raw = nil;
        procRead([dir stringByAppendingPathComponent:@"cmdline"], 65536, &raw);
        NSMutableArray *argv = [NSMutableArray array];
        const char *bytes = [raw bytes];
        NSUInteger len = [raw length];
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < len; i++) {
            if (bytes[i] == '\0') {
                NSString *arg = [[[NSString alloc] initWithBytes:bytes + start
                                                          length:i - start
                                                        encoding:NSUTF8StringEncoding] autorelease];
                if (arg) [argv addObject:arg];
                start = i + 1;
            }
        }
        [table addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:pid], @"pid",
            [NSNumber numberWithUnsignedInt:(unsigned)st.st_uid], @"uid",
            comm, @"comm", argv, @"argv", nil]];
    }
#endif
    return table;
}

+ (NSArray *)processTable
{
    return [self processTableMatching:^BOOL(NSString *comm) { return YES; }];
}

+ (NSArray *)jackdProcesses
{
    NSArray *table = [self processTableMatching:^BOOL(NSString *comm) {
        return [comm isEqualToString:@"jackd"] || [comm isEqualToString:@"jackdbus"];
    }];
    return [self jackdProcessesInTable:table forUID:getuid()];
}

+ (NSArray *)jackdProcessIDs
{
    NSMutableArray *pids = [NSMutableArray array];
    for (NSDictionary *entry in [self jackdProcesses]) {
        [pids addObject:[entry objectForKey:@"pid"]];
    }
    return pids;
}

+ (BOOL)isJackdAvailableWithPATH:(NSString *)path
                      fileExists:(BOOL (^)(NSString *))isExecutable
{
    NSMutableArray *dirs = [NSMutableArray array];
    for (NSString *dir in [path componentsSeparatedByString:@":"]) {
        if ([dir length] > 0) [dirs addObject:dir];
    }
    [dirs addObject:@"/usr/bin"];
    [dirs addObject:@"/usr/local/bin"];
    for (NSString *dir in dirs) {
        if (isExecutable([dir stringByAppendingPathComponent:@"jackd"])) return YES;
    }
    return NO;
}

+ (BOOL)isJackdAvailable
{
#ifdef __linux__
    const char *env = getenv("PATH");
    return [self isJackdAvailableWithPATH:env ? [NSString stringWithUTF8String:env] : @""
                               fileExists:^BOOL(NSString *p) {
        return [[NSFileManager defaultManager] isExecutableFileAtPath:p];
    }];
#else
    return NO;
#endif
}

+ (JackConnection *)runningServerNamed:(NSString *)serverName
{
    if ([[self jackdProcessIDs] count] == 0) return nil;
    return [JackConnection openWithServerName:serverName];
}

+ (JackConnection *)runningServer
{
    return [self runningServerNamed:nil];
}

#pragma mark jackd command line

+ (NSArray *)jackdArgumentsForSettings:(NSDictionary *)settings
                                 error:(NSString **)error
{
    NSString *device = [settings objectForKey:JackdDevice];
    if (![device isKindOfClass:[NSString class]] || !validDeviceName(device)) {
        if (error) *error = [NSString stringWithFormat:@"invalid ALSA device '%@'", device];
        return nil;
    }
    NSInteger rate, frames, periods;
    if (!optionalInteger(settings, JackdSampleRate, 48000, &rate) || !validRate(rate)) {
        if (error) *error = [NSString stringWithFormat:@"invalid sample rate '%@'",
                             [settings objectForKey:JackdSampleRate]];
        return nil;
    }
    if (!optionalInteger(settings, JackdBufferFrames, 1024, &frames) || !validFrames(frames)) {
        if (error) *error = [NSString stringWithFormat:
            @"invalid buffer size '%@' (power of two from 16 to 8192)",
            [settings objectForKey:JackdBufferFrames]];
        return nil;
    }
    if (!optionalInteger(settings, JackdPeriods, 3, &periods) || !validPeriods(periods)) {
        if (error) *error = [NSString stringWithFormat:@"invalid period count '%@'",
                             [settings objectForKey:JackdPeriods]];
        return nil;
    }
    NSString *server = [settings objectForKey:JackdServerName];
    if (server != nil && (![server isKindOfClass:[NSString class]] || !validServerName(server))) {
        if (error) *error = [NSString stringWithFormat:@"invalid server name '%@'", server];
        return nil;
    }

    NSMutableArray *args = [NSMutableArray array];
    if (server) [args addObjectsFromArray:[NSArray arrayWithObjects:@"-n", server, nil]];
    [args addObjectsFromArray:[NSArray arrayWithObjects:@"-d", @"alsa", @"-d", device, nil]];
    [args addObjectsFromArray:[NSArray arrayWithObjects:
        @"-r", [NSString stringWithFormat:@"%ld", (long)rate],
        @"-p", [NSString stringWithFormat:@"%ld", (long)frames],
        @"-n", [NSString stringWithFormat:@"%ld", (long)periods], nil]];
    return args;
}

+ (NSString *)clockDeviceForJackdArguments:(NSArray *)argv
{
    // The first -d / --driver names the driver; every later -d / --device
    // belongs to the driver, so a driver's -d must not be mistaken for the
    // server's.  Arguments before the driver are server options.
    NSUInteger count = [argv count];
    NSUInteger i = 0;
    NSString *driver = nil;
    for (; i < count && driver == nil; i++) {
        NSString *a = [argv objectAtIndex:i];
        if ([a isEqualToString:@"-d"] || [a isEqualToString:@"--driver"]) {
            if (i + 1 < count) driver = [argv objectAtIndex:++i];
            else return nil;
        } else if ([a hasPrefix:@"--driver="]) {
            driver = [a substringFromIndex:9];
        } else if ([a hasPrefix:@"-d"] && [a length] > 2) {
            driver = [a substringFromIndex:2];
        }
    }
    if (![driver isEqualToString:@"alsa"]) return nil;

    NSString *device = nil;
    for (; i < count; i++) {
        NSString *a = [argv objectAtIndex:i];
        if ([a isEqualToString:@"-d"] || [a isEqualToString:@"--device"]) {
            if (i + 1 < count) device = [argv objectAtIndex:++i];
        } else if ([a hasPrefix:@"--device="]) {
            device = [a substringFromIndex:9];
        } else if ([a hasPrefix:@"-d"] && [a length] > 2) {
            device = [a substringFromIndex:2];
        }
    }
    // jackd's own default when the alsa driver is given no device.
    return device ? device : @"hw:0";
}

#pragma mark Bridges

+ (BOOL)isDevice:(NSDictionary *)device clockDevice:(NSString *)clockDevice
{
    if (clockDevice == nil) return NO;
    NSString *card = nil;
    NSString *dev = nil;
    parseHW(clockDevice, &card, &dev);
    return deviceIsClock(device, card, dev);
}

+ (NSString *)bridgeClientNameForCardId:(NSString *)cardId direction:(NSString *)direction
{
    NSString *prefix = [direction isEqualToString:@"capture"] ? kInBridgePrefix : kOutBridgePrefix;
    return [prefix stringByAppendingString:sanitizedClientSuffix(cardId)];
}

+ (NSDictionary *)selectedDeviceInDevices:(NSArray *)devices
                                 jackCard:(NSString *)jackCard
                              alsaDefault:(NSString *)alsaDefault
                                selection:(NSString **)selection
{
    if (selection) *selection = nil;
    if (jackCard != nil) {
        if (selection) *selection = jackCard;
        for (NSDictionary *d in devices) {
            if ([[d objectForKey:JackDeviceCardId] isEqualToString:jackCard]) return d;
        }
        return nil;
    }
    if (alsaDefault == nil) return nil;
    if (selection) *selection = alsaDefault;
    NSString *card = nil;
    NSString *dev = nil;
    if ([alsaDefault hasPrefix:@"hw:"]) {
        parseHW(alsaDefault, &card, &dev);
    } else {
        NSRange dot = [alsaDefault rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location == NSNotFound || dot.location == 0) return nil;
        card = [alsaDefault substringToIndex:dot.location];
        dev = [alsaDefault substringFromIndex:NSMaxRange(dot)];
    }
    for (NSDictionary *d in devices) {
        if (deviceIsClock(d, card, dev)) return d;
    }
    return nil;
}

+ (NSDictionary *)bridgePlanForPlaybackDevices:(NSArray *)playback
                                captureDevices:(NSArray *)capture
                                runningBridges:(NSArray *)running
                                   clockDevice:(NSString *)clockDevice
                                    sampleRate:(NSUInteger)rate
                                  bufferFrames:(NSUInteger)frames
                                       periods:(NSUInteger)periods
                                    serverName:(NSString *)serverName
{
    NSMutableArray *errors = [NSMutableArray array];
    NSMutableArray *start = [NSMutableArray array];
    NSMutableArray *stop = [NSMutableArray array];
    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
        start, @"start", stop, @"stop", errors, @"errors", nil];

    if (!validRate(rate) || !validFrames(frames) || !validPeriods(periods)
        || (serverName != nil && !validServerName(serverName))) {
        [errors addObject:@"invalid bridge parameters (rate, buffer size, periods or server name)"];
        return result;
    }

    NSString *clockCard = nil;
    NSString *clockDev = @"0";
    if (clockDevice != nil) parseHW(clockDevice, &clockCard, &clockDev);

    NSMutableSet *wanted = [NSMutableSet set];
    NSArray *lists[2] = { playback, capture };
    for (int pass = 0; pass < 2; pass++) {
        BOOL isCapture = (pass == 1);
        for (NSDictionary *device in lists[pass]) {
            NSString *cardId = [device objectForKey:JackDeviceCardId];
            NSString *hw = [device objectForKey:JackDeviceHW];
            if (![cardId isKindOfClass:[NSString class]] || [cardId length] == 0) {
                [errors addObject:@"device without a card id"];
                continue;
            }
            // The clock device is already in JACK as the system client.
            if (deviceIsClock(device, clockCard, clockDev)) continue;
            if (![hw isKindOfClass:[NSString class]] || !validDeviceName(hw)) {
                [errors addObject:[NSString stringWithFormat:
                    @"device '%@': invalid ALSA name '%@'", cardId, hw]];
                continue;
            }
            NSString *name = [self bridgeClientNameForCardId:cardId
                                                   direction:isCapture ? @"capture" : @"playback"];
            if ([wanted containsObject:name]) continue;
            [wanted addObject:name];
            if ([running containsObject:name]) continue;
            NSMutableArray *args = [NSMutableArray arrayWithObjects:
                @"-j", name, @"-d", hw,
                @"-r", [NSString stringWithFormat:@"%lu", (unsigned long)rate],
                @"-p", [NSString stringWithFormat:@"%lu", (unsigned long)frames],
                @"-n", [NSString stringWithFormat:@"%lu", (unsigned long)periods],
                @"-q", @"1", nil];
            if (serverName) [args addObjectsFromArray:[NSArray arrayWithObjects:@"-S", serverName, nil]];
            [start addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                name, @"name",
                isCapture ? @"alsa_in" : @"alsa_out", @"executable",
                args, @"arguments", hw, @"hw",
                isCapture ? @"capture" : @"playback", @"direction", nil]];
        }
    }
    for (NSString *name in running) {
        // Only clients we name ourselves are ours to stop.
        if (![name hasPrefix:kOutBridgePrefix] && ![name hasPrefix:kInBridgePrefix]) continue;
        if (![wanted containsObject:name]) [stop addObject:name];
    }
    return result;
}

#pragma mark Patchbay

+ (NSDictionary *)patchbayPlanForPorts:(NSArray *)ports
                          outputClient:(NSString *)outputClient
                           inputClient:(NSString *)inputClient
{
    NSMutableArray *connect = [NSMutableArray array];
    NSMutableArray *disconnect = [NSMutableArray array];
    NSMutableArray *problems = [NSMutableArray array];
    planSide(ports, outputClient, YES, connect, disconnect, problems);
    planSide(ports, inputClient, NO, connect, disconnect, problems);
    return [NSDictionary dictionaryWithObjectsAndKeys:
        connect, @"connect", disconnect, @"disconnect", problems, @"problems", nil];
}

#pragma mark asoundrc

// Port names written unquoted into the ALSA configuration: only what device
// clients (system, gsout-*, gsin-*) are named with.
static BOOL validConfigPortName(NSString *s)
{
    return [s isKindOfClass:[NSString class]] && allCharsIn(s, "_:.-", 128);
}

// "    playback_ports {\n        0 a\n        1 b\n    }\n"; one port serves
// both channels, so a mono device still plays and records stereo streams.
static NSString *portsSection(NSString *key, NSArray *ports)
{
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *p in ports) {
        if (validConfigPortName(p)) [names addObject:p];
        if ([names count] == 2) break;
    }
    if ([names count] == 0) return @"";
    if ([names count] == 1) [names addObject:[names objectAtIndex:0]];
    return [NSString stringWithFormat:@"    %@ {\n        0 %@\n        1 %@\n    }\n",
            key, [names objectAtIndex:0], [names objectAtIndex:1]];
}

+ (NSString *)asoundrcJackBlockWithPlaybackPorts:(NSArray *)playback capturePorts:(NSArray *)capture
{
    // The jack plugin connects its ports when a stream starts and fails the
    // whole stream when a named port does not exist then, so the block names
    // the ports the patchbay routes to now and is rewritten when that moves.
    // The plugin (alsa-plugins 1.2.12) refuses to open a direction whose
    // section is missing: without any capture port recording fails with
    // "define the capture_ports section" while playback keeps working.
    // Appended after the generated blocks, this pcm.!default replaces theirs
    // (a later "!" definition overrides); ctl.!default stays the card's mixer.
    return [NSString stringWithFormat:@"%@%@%@%@%@",
        kBlockBegin,
        @"# Managed by Sound Preferences while JACK is running.\n"
        @"pcm.!default {\n"
        @"    type plug\n"
        @"    slave.pcm \"jack_gershwin\"\n"
        @"}\n"
        @"\n"
        @"pcm.jack_gershwin {\n"
        @"    type jack\n",
        portsSection(@"playback_ports", playback),
        portsSection(@"capture_ports", capture),
        @"}\n"
        @"# END gershwin jack\n"];
}

+ (NSString *)asoundrcJackBlock
{
    return [self asoundrcJackBlockWithPlaybackPorts:
                     [NSArray arrayWithObjects:@"system:playback_1", @"system:playback_2", nil]
                                       capturePorts:
                     [NSArray arrayWithObjects:@"system:capture_1", @"system:capture_2", nil]];
}

// The device ports of client facing the applications, else those of any
// device, the system client first.
static NSArray *asoundrcPortsOf(NSArray *ports, NSString *client, BOOL playback)
{
    NSArray *names = client ? portNamesOfClient(ports, client, !playback) : [NSArray array];
    if ([names count] > 0) return names;
    names = portNamesOfClient(ports, kSystemClient, !playback);
    if ([names count] > 0) return names;
    NSArray *all = [[devicePortNames(ports, !playback) allObjects]
        sortedArrayUsingFunction:(NSInteger (*)(id, id, void *))comparePortNames context:NULL];
    return all;
}

+ (NSString *)asoundrcJackBlockForPorts:(NSArray *)ports
                           outputClient:(NSString *)outputClient
                            inputClient:(NSString *)inputClient
{
    return [self asoundrcJackBlockWithPlaybackPorts:asoundrcPortsOf(ports, outputClient, YES)
                                       capturePorts:asoundrcPortsOf(ports, inputClient, NO)];
}

// The block's range (including its END line), NSNotFound when absent; nil
// *error and NSNotFound location for "absent", error set for a damaged block.
static NSRange findBlock(NSString *text, NSString **error)
{
    NSRange none = NSMakeRange(NSNotFound, 0);
    NSRange begin = NSMakeRange(NSNotFound, 0);
    NSUInteger from = 0;
    NSUInteger count = 0;
    while (from < [text length]) {
        NSRange r = [text rangeOfString:kBlockBegin options:0
                                  range:NSMakeRange(from, [text length] - from)];
        if (r.location == NSNotFound) break;
        if (r.location == 0 || [text characterAtIndex:r.location - 1] == '\n') {
            if (count++ == 0) begin = r;
        }
        from = NSMaxRange(r);
    }
    if (count == 0) return none;
    if (count > 1) {
        if (error) *error = @"more than one gershwin jack block in .asoundrc";
        return none;
    }
    NSUInteger after = NSMaxRange(begin);
    NSRange end = [text rangeOfString:@"# END gershwin jack" options:0
                                range:NSMakeRange(after, [text length] - after)];
    if (end.location == NSNotFound || [text characterAtIndex:end.location - 1] != '\n') {
        if (error) *error = @"gershwin jack block in .asoundrc has no END line";
        return none;
    }
    NSUInteger stop = NSMaxRange(end);
    if (stop < [text length] && [text characterAtIndex:stop] == '\n') stop++;
    return NSMakeRange(begin.location, stop - begin.location);
}

+ (BOOL)asoundrcHasJackBlock:(NSString *)text
{
    NSString *error = nil;
    NSRange r = findBlock(text, &error);
    return r.location != NSNotFound || error != nil;
}

+ (NSString *)asoundrcByApplyingJackBlockTo:(NSString *)text error:(NSString **)error
{
    return [self asoundrcByApplyingJackBlock:[self asoundrcJackBlock] to:text error:error];
}

+ (NSString *)asoundrcByApplyingJackBlock:(NSString *)block to:(NSString *)text error:(NSString **)error
{
    NSString *problem = nil;
    NSRange r = findBlock(text, &problem);
    if (problem) {
        if (error) *error = problem;
        return nil;
    }
    if (r.location != NSNotFound) {
        return [text stringByReplacingCharactersInRange:r withString:block];
    }
    // Always a "\n" in front (unless the file is empty), so removal can take
    // exactly that "\n" and the block back out and return the original bytes.
    if ([text length] == 0) return block;
    return [[text stringByAppendingString:@"\n"] stringByAppendingString:block];
}

+ (NSString *)asoundrcByRemovingJackBlockFrom:(NSString *)text error:(NSString **)error
{
    NSString *problem = nil;
    NSRange r = findBlock(text, &problem);
    if (problem) {
        if (error) *error = problem;
        return nil;
    }
    if (r.location == NSNotFound) return text;
    if (r.location > 0) {
        r.location -= 1;
        r.length += 1;
    }
    return [text stringByReplacingCharactersInRange:r withString:@""];
}

#pragma mark Settings

+ (NSString *)defaultSettingsPath
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @".config/gershwin/sound-defaults.plist"];
}

+ (NSDictionary *)settingsAtPath:(NSString *)path
{
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    id use = [raw objectForKey:JackSettingUseJack];
    [result setObject:[NSNumber numberWithBool:
        [use isKindOfClass:[NSNumber class]] ? [use boolValue] : NO]
               forKey:JackSettingUseJack];
    NSInteger v;
    id value = [raw objectForKey:JackSettingBufferFrames];
    [result setObject:[NSNumber numberWithInteger:
        (value && integerFrom(value, &v) && validFrames(v)) ? v : 1024]
               forKey:JackSettingBufferFrames];
    value = [raw objectForKey:JackSettingSampleRate];
    [result setObject:[NSNumber numberWithInteger:
        (value && integerFrom(value, &v) && validRate(v)) ? v : 48000]
               forKey:JackSettingSampleRate];
    for (NSString *key in [NSArray arrayWithObjects:JackSettingOutputCard,
                                                    JackSettingInputCard, nil]) {
        NSString *card = [raw objectForKey:key];
        if ([card isKindOfClass:[NSString class]] && validCardId(card)) {
            [result setObject:card forKey:key];
        }
    }
    // Written by the ALSA backend as "<card id>.<device>" (or "hw:N,M" for a
    // card without an id); read here only to know what the user last chose.
    for (NSString *key in [NSArray arrayWithObjects:JackSettingALSAOutput,
                                                    JackSettingALSAInput, nil]) {
        NSString *name = [raw objectForKey:key];
        if ([name isKindOfClass:[NSString class]] && validDeviceName(name)) {
            [result setObject:name forKey:key];
        }
    }
    return result;
}

+ (BOOL)setSettings:(NSDictionary *)settings atPath:(NSString *)path error:(NSString **)error
{
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        // An unreadable file is not silently replaced: it holds the sound
        // device choices too.
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
        if (existing == nil) {
            if (error) *error = [NSString stringWithFormat:@"%@ exists but is not a readable property list", path];
            return NO;
        }
        [plist addEntriesFromDictionary:existing];
    }
    for (NSString *key in settings) {
        id value = [settings objectForKey:key];
        NSInteger v;
        if ([key isEqualToString:JackSettingUseJack]) {
            if (![value isKindOfClass:[NSNumber class]]) {
                if (error) *error = @"UseJack must be a boolean";
                return NO;
            }
            [plist setObject:[NSNumber numberWithBool:[value boolValue]] forKey:key];
        } else if ([key isEqualToString:JackSettingBufferFrames]) {
            if (!integerFrom(value, &v) || !validFrames(v)) {
                if (error) *error = [NSString stringWithFormat:@"invalid JackBufferFrames '%@'", value];
                return NO;
            }
            [plist setObject:[NSNumber numberWithInteger:v] forKey:key];
        } else if ([key isEqualToString:JackSettingSampleRate]) {
            if (!integerFrom(value, &v) || !validRate(v)) {
                if (error) *error = [NSString stringWithFormat:@"invalid JackSampleRate '%@'", value];
                return NO;
            }
            [plist setObject:[NSNumber numberWithInteger:v] forKey:key];
        } else if ([key isEqualToString:JackSettingOutputCard]
                   || [key isEqualToString:JackSettingInputCard]) {
            if ([value isKindOfClass:[NSNull class]]) {
                [plist removeObjectForKey:key];
            } else if ([value isKindOfClass:[NSString class]] && validCardId(value)) {
                [plist setObject:value forKey:key];
            } else {
                if (error) *error = [NSString stringWithFormat:@"invalid %@ '%@'", key, value];
                return NO;
            }
        } else {
            if (error) *error = [NSString stringWithFormat:@"unknown JACK setting '%@'", key];
            return NO;
        }
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                        attributes:nil error:&dirError]) {
        if (error) *error = [NSString stringWithFormat:@"cannot create %@: %@", dir, dirError];
        return NO;
    }
    if (![plist writeToFile:path atomically:YES]) {
        if (error) *error = [NSString stringWithFormat:@"cannot write %@", path];
        return NO;
    }
    return YES;
}

+ (NSDictionary *)settings
{
    return [self settingsAtPath:[self defaultSettingsPath]];
}

+ (BOOL)setSettings:(NSDictionary *)settings error:(NSString **)error
{
    return [self setSettings:settings atPath:[self defaultSettingsPath] error:error];
}

@end
