/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Service Discovery Manager Implementation - Simplified to use NSNetService only
 */

#import "GSServiceDiscoveryManager.h"
#import <sys/utsname.h>
#import <unistd.h>
#import <signal.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>

// State file location
#define STATE_FILE_PATH @"/var/lib/gershwin/sharing-services-state.plist"
#define STATE_FILE_DIR @"/var/lib/gershwin"

// Get primary non-loopback IPv4 address as a C string.
// Returns 0 on success, -1 on failure.
static int get_primary_ip(char *buf, size_t buflen)
{
    struct ifaddrs *ifaddr, *ifa;
    int ret = -1;

    if (getifaddrs(&ifaddr) == -1) return -1;

    for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (ifa->ifa_flags & IFF_LOOPBACK) continue;
        if (!(ifa->ifa_flags & IFF_UP)) continue;

        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, (socklen_t)buflen)) {
            ret = 0;
            break;
        }
    }
    freeifaddrs(ifaddr);
    return ret;
}

@interface GSServiceDiscoveryManager (Private)
- (NSString *)getHostname;
- (NSData *)txtRecordDataFromDictionary:(NSDictionary *)dict;
@end

@implementation GSServiceDiscoveryManager

static GSServiceDiscoveryManager *sharedInstance = nil;

+ (instancetype)sharedManager
{
    @synchronized([GSServiceDiscoveryManager class]) {
        if (sharedInstance == nil) {
            sharedInstance = [[GSServiceDiscoveryManager alloc] init];
        }
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        NSDebugLog(@"GSServiceDiscoveryManager: init starting");

        lock = [[NSRecursiveLock alloc] init];
        registeredServices = [[NSMutableDictionary alloc] init];
        backgroundPIDs = [[NSMutableDictionary alloc] init];
        computerName = nil;

        NSDebugLog(@"GSServiceDiscoveryManager: Checking for NSNetService");

        // Check if NSNetService is available (it handles dns-sd/Avahi internally)
        Class netServiceClass = NSClassFromString(@"NSNetService");
        if (netServiceClass != nil) {
            backend = GSServiceBackendNSNetService;
            isAvailable = YES;
            NSDebugLog(@"GSServiceDiscoveryManager: NSNetService available");
        } else {
            backend = GSServiceBackendNone;
            isAvailable = NO;
            NSDebugLog(@"GSServiceDiscoveryManager: NSNetService NOT available");
        }

        NSDebugLog(@"GSServiceDiscoveryManager: init complete (state restoration deferred)");
        // NOTE: State restoration is now called explicitly when needed, not automatically

        // Clean up any stale background mDNS publishers from a previous run
        [self cleanupStaleBackgroundPublishers];
    }
    return self;
}

- (void)cleanupStaleBackgroundPublishers
{
    // Read the state file and kill any PIDs from a previous session.
    // This prevents stale processes from conflicting with new announcements
    // when the app restarts after a crash.
    NSString *stateFile = STATE_FILE_PATH;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:stateFile];
    if (!state || [state count] == 0) {
        return;
    }
    NSEnumerator *keyEnum = [state keyEnumerator];
    NSString *keyStr;
    while ((keyStr = [keyEnum nextObject])) {
        NSDictionary *info = [state objectForKey:keyStr];
        NSNumber *oldPid = [info objectForKey:@"bgPid"];
        if (oldPid && [oldPid intValue] > 0) {
            pid_t pid = [oldPid intValue];
            if (kill(pid, 0) == 0) {
                // Process exists and we can signal it - kill it
                kill(pid, SIGTERM);
                // Give it a moment then reap
                int status;
                waitpid(pid, &status, WNOHANG);
            }
        }
    }
}

- (void)dealloc
{
    [lock lock];

    // Stop all announced services
    NSArray *serviceKeys = [registeredServices allKeys];
    for (NSNumber *serviceTypeNum in serviceKeys) {
        GSServiceType serviceType = [serviceTypeNum intValue];
        [self unannounceService:serviceType];
    }

    // Stop the background address publisher
    [self stopAddressPublisher];

    [registeredServices release];
    [backgroundPIDs release];
    [computerName release];
    [lock unlock];
    [lock release];

    [super dealloc];
}

#pragma mark - Public API

- (BOOL)isAvailable
{
    return isAvailable;
}

- (GSServiceBackend)backend
{
    return backend;
}

- (NSString *)backendName
{
    return isAvailable ? @"NSNetService" : @"None";
}

- (void)setComputerName:(NSString *)name
{
    [lock lock];
    ASSIGN(computerName, name);

    // Update all announced services with new name
    NSArray *serviceKeys = [[registeredServices allKeys] copy];
    for (NSNumber *serviceTypeNum in serviceKeys) {
        GSServiceType serviceType = [serviceTypeNum intValue];
        id service = [registeredServices objectForKey:serviceTypeNum];

        // Re-announce with new name if using NSNetService
        if ([service isKindOfClass:[NSNetService class]]) {
            NSNetService *netService = (NSNetService *)service;
            NSInteger port = [netService port];
            NSDictionary *txtDict = nil; // TODO: Extract from current service if needed

            // Stop and re-announce with new name
            [self unannounceService:serviceType];
            [self announceService:serviceType port:port txtRecord:txtDict];
        }
    }

    // Re-publish the hostname address with the new name
    [self launchAddressPublisher:name];

    [serviceKeys release];
    [lock unlock];
}

- (NSString *)serviceTypeString:(GSServiceType)serviceType
{
    switch (serviceType) {
        case GSServiceTypeSSH:
            return @"_ssh._tcp.";
        case GSServiceTypeVNC:
            return @"_rfb._tcp.";
        case GSServiceTypeSFTP:
            return @"_sftp-ssh._tcp.";
        case GSServiceTypeAFP:
            return @"_afpovertcp._tcp.";
        case GSServiceTypeSMB:
            return @"_smb._tcp.";
        case GSServiceTypeWebDAV:
            return @"_webdav._tcp.";
        case GSServiceTypeWeb:
            return @"_http._tcp.";
        case GSServiceTypeMedia:
            return @"_dlna._tcp.";
        case GSServiceTypeRDP:
            return @"_rdp._tcp.";
        default:
            return nil;
    }
}

- (NSInteger)defaultPortForService:(GSServiceType)serviceType
{
    switch (serviceType) {
        case GSServiceTypeSSH:
        case GSServiceTypeSFTP:
            return 22;
        case GSServiceTypeVNC:
            return 5900;
        case GSServiceTypeAFP:
            return 548;
        case GSServiceTypeSMB:
            return 445;
        case GSServiceTypeWebDAV:
            return 8080;
        case GSServiceTypeWeb:
            return 80;
        case GSServiceTypeMedia:
            return 8200;
        case GSServiceTypeRDP:
            return 3389;
        default:
            return 0;
    }
}

- (NSString *)getHostname
{
    if (computerName) {
        return computerName;
    }

    struct utsname buf;
    if (uname(&buf) == 0) {
        return [NSString stringWithUTF8String:buf.nodename];
    }

    return @"localhost";
}

- (NSData *)txtRecordDataFromDictionary:(NSDictionary *)dict
{
    if (!dict || [dict count] == 0) {
        return nil;
    }

    // Use NSNetService's built-in method if available
    Class netServiceClass = NSClassFromString(@"NSNetService");
    if ([netServiceClass respondsToSelector:@selector(dataFromTXTRecordDictionary:)]) {
        return [netServiceClass performSelector:@selector(dataFromTXTRecordDictionary:)
                                     withObject:dict];
    }

    return nil;
}

#pragma mark - Service Announcement

- (BOOL)announceService:(GSServiceType)serviceType
                   port:(NSInteger)port
              txtRecord:(NSDictionary *)txtRecord
{
    if (!isAvailable) {
        NSDebugLog(@"GSServiceDiscoveryManager: Cannot announce service - NSNetService not available");
        return NO;
    }

    [lock lock];

    NSNumber *serviceKey = [NSNumber numberWithInt:serviceType];

    // Check if already announced
    if ([registeredServices objectForKey:serviceKey] != nil) {
        NSDebugLog(@"GSServiceDiscoveryManager: Service type %d already announced, re-announcing", serviceType);
        [self unannounceService:serviceType];
    }

    NSString *serviceTypeStr = [self serviceTypeString:serviceType];
    if (!serviceTypeStr) {
        NSDebugLog(@"GSServiceDiscoveryManager: Invalid service type: %d", serviceType);
        [lock unlock];
        return NO;
    }

    NSString *hostname = [self getHostname];

    // Launch the address publisher on the first service announcement,
    // so hostname.local resolves even without an active service.
    if (![backgroundPIDs objectForKey:[NSNumber numberWithInt:-1]]) {
        [self launchAddressPublisher:hostname];
    }
    NSDebugLog(@"GSServiceDiscoveryManager: Announcing %@ on port %ld as %@",
          serviceTypeStr, (long)port, hostname);

    BOOL success = NO;

    // Use NSNetService API (it handles dns-sd/Avahi internally)
    Class netServiceClass = NSClassFromString(@"NSNetService");
    if (netServiceClass) {
        NSNetService *service = [[netServiceClass alloc] initWithDomain:@""
                                                                   type:serviceTypeStr
                                                                   name:hostname
                                                                   port:(int)port];
        if (service) {
            // Set TXT record if provided
            if (txtRecord) {
                NSData *txtData = [self txtRecordDataFromDictionary:txtRecord];
                if (txtData && [service respondsToSelector:@selector(setTXTRecordData:)]) {
                    [service performSelector:@selector(setTXTRecordData:) withObject:txtData];
                }
            }

            // Publish the service
            [service publish];
            [registeredServices setObject:service forKey:serviceKey];
            [service release];
            success = YES;

            // Also spawn a standalone mDNS publisher so the announcement
            // survives the app process exiting.
            [self launchBackgroundPublisher:serviceType
                                       port:port
                                   hostname:hostname];

            NSDebugLog(@"GSServiceDiscoveryManager: Successfully announced service via NSNetService");
        }
    }

    if (success) {
        // Save state for reboot persistence
        [self saveState];
    }

    [lock unlock];
    return success;
}

- (void)unannounceService:(GSServiceType)serviceType
{
    [lock lock];

    NSNumber *serviceKey = [NSNumber numberWithInt:serviceType];
    id service = [registeredServices objectForKey:serviceKey];

    if (!service) {
        NSDebugLog(@"GSServiceDiscoveryManager: Service type %d is not announced", serviceType);
        [lock unlock];
        return;
    }

    NSDebugLog(@"GSServiceDiscoveryManager: Unannouncing service type %d", serviceType);

    if ([service isKindOfClass:[NSNetService class]]) {
        // Stop NSNetService (it handles cleanup internally)
        NSNetService *netService = (NSNetService *)service;
        [netService stop];
    }

    // Also stop the standalone background publisher if one is running
    [self stopBackgroundPublisher:serviceType];

    [registeredServices removeObjectForKey:serviceKey];

    // Save state
    [self saveState];

    [lock unlock];
}

- (BOOL)isServiceAnnounced:(GSServiceType)serviceType
{
    [lock lock];
    NSNumber *serviceKey = [NSNumber numberWithInt:serviceType];
    BOOL announced = ([registeredServices objectForKey:serviceKey] != nil);
    [lock unlock];
    return announced;
}

- (NSArray *)announcedServices
{
    [lock lock];
    NSArray *keys = [registeredServices allKeys];
    [lock unlock];
    return keys;
}

#pragma mark - Background Publishers

- (void)launchBackgroundPublisher:(GSServiceType)serviceType
                             port:(NSInteger)port
                         hostname:(NSString *)hostname
{
    NSString *typeStr = [self serviceTypeString:serviceType];
    if (!typeStr) return;

    // Stop any existing publisher for this service type first
    [self stopBackgroundPublisher:serviceType];

    // Convert to C strings before forking - ObjC messaging is not
    // async-signal-safe and must not happen in the child.
    const char *hostnameC = [hostname UTF8String];
    const char *typeC = [typeStr UTF8String];
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%ld", (long)port);

    pid_t pid = fork();
    if (pid == 0) {
        // Child - daemonize, then exec the mDNS publisher
        setsid();
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        // Try avahi-publish-service first (supports -s to daemonize)
        execlp("avahi-publish-service", "avahi-publish-service", "-s",
               hostnameC, typeC, portStr, NULL);
        // Fallback to dns-sd -R (name type domain port)
        execlp("dns-sd", "dns-sd", "-R",
               hostnameC, typeC, "local.", portStr, NULL);
        // Neither found - exit
        _exit(1);
    } else if (pid > 0) {
        // Parent - store the PID so we can stop it later
        [backgroundPIDs setObject:[NSNumber numberWithInt:pid]
                           forKey:[NSNumber numberWithInt:serviceType]];
        // Don't waitpid - the child is a daemon; we reap on stop
    }
}

- (void)stopBackgroundPublisher:(GSServiceType)serviceType
{
    NSNumber *key = [NSNumber numberWithInt:serviceType];
    NSNumber *pidNum = [backgroundPIDs objectForKey:key];
    if (pidNum) {
        pid_t pid = [pidNum intValue];
        kill(pid, SIGTERM);
        // Reap the child to avoid a zombie
        int status;
        waitpid(pid, &status, WNOHANG);
        [backgroundPIDs removeObjectForKey:key];
    }
}

#pragma mark - Address Publisher

- (void)launchAddressPublisher:(NSString *)hostname
{
    // Stop any existing address publisher first
    [self stopAddressPublisher];

    const char *hostnameC = [hostname UTF8String];
    char ipStr[INET_ADDRSTRLEN] = "";
    get_primary_ip(ipStr, sizeof(ipStr));

    pid_t pid = fork();
    if (pid == 0) {
        // Child - daemonize
        setsid();
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        // Publish the hostname A record so hostname.local resolves.
        // avahi-publish-address -s daemonizes automatically.
        if (ipStr[0] != '\0') {
            execlp("avahi-publish-address", "avahi-publish-address", "-s",
                   hostnameC, ipStr, NULL);
        }
        // Fallback for mDNSResponder: register a _workstation service.
        // This causes the responder to advertise the hostname via its SRV
        // record, making the hostname resolvable through the service.
        execlp("dns-sd", "dns-sd", "-R",
               hostnameC, "_workstation._tcp.", "local.", "9", NULL);
        _exit(1);
    } else if (pid > 0) {
        // Parent - store the PID so we can stop it later
        [backgroundPIDs setObject:[NSNumber numberWithInt:pid]
                           forKey:[NSNumber numberWithInt:-1]];
    }
}

- (void)stopAddressPublisher
{
    NSNumber *addrKey = [NSNumber numberWithInt:-1];
    NSNumber *pidNum = [backgroundPIDs objectForKey:addrKey];
    if (pidNum) {
        pid_t pid = [pidNum intValue];
        kill(pid, SIGTERM);
        int status;
        waitpid(pid, &status, WNOHANG);
        [backgroundPIDs removeObjectForKey:addrKey];
    }
}

#pragma mark - State Persistence

- (void)saveState
{
    [lock lock];

    // Create state directory if it doesn't exist
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stateDir = STATE_FILE_DIR;

    BOOL isDir;
    if (![fm fileExistsAtPath:stateDir isDirectory:&isDir]) {
        NSError *error = nil;
        if (![fm createDirectoryAtPath:stateDir
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&error]) {
            NSDebugLog(@"GSServiceDiscoveryManager: Failed to create state directory: %@", error);
            [lock unlock];
            return;
        }
    }

    // Build state dictionary
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSEnumerator *keyEnum = [registeredServices keyEnumerator];
    NSNumber *serviceKey;

    while ((serviceKey = [keyEnum nextObject])) {
        id service = [registeredServices objectForKey:serviceKey];
        NSMutableDictionary *serviceInfo = [NSMutableDictionary dictionary];

        if ([service isKindOfClass:[NSNetService class]]) {
            NSNetService *netService = (NSNetService *)service;
            [serviceInfo setObject:[NSNumber numberWithInt:[netService port]] forKey:@"port"];
            [serviceInfo setObject:[self serviceTypeString:[serviceKey intValue]] forKey:@"type"];
        }

        // Also persist the PID of the standalone background publisher so stale
        // processes can be cleaned up when the app restarts after a crash.
        NSNumber *bgPid = [backgroundPIDs objectForKey:serviceKey];
        if (bgPid) {
            [serviceInfo setObject:bgPid forKey:@"bgPid"];
        }

        [state setObject:serviceInfo forKey:[serviceKey stringValue]];
    }

    // Write to disk
    BOOL success = [state writeToFile:STATE_FILE_PATH atomically:YES];
    if (success) {
        NSDebugLog(@"GSServiceDiscoveryManager: Saved state to %@", STATE_FILE_PATH);
    } else {
        NSDebugLog(@"GSServiceDiscoveryManager: Failed to save state to %@", STATE_FILE_PATH);
    }

    [lock unlock];
}

- (void)restoreState
{
    if (!isAvailable) {
        NSDebugLog(@"GSServiceDiscoveryManager: Skipping state restoration - NSNetService not available");
        return;
    }

    [lock lock];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:STATE_FILE_PATH]) {
        NSDebugLog(@"GSServiceDiscoveryManager: No saved state found");
        [lock unlock];
        return;
    }

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:STATE_FILE_PATH];
    if (!state || [state count] == 0) {
        NSDebugLog(@"GSServiceDiscoveryManager: No services to restore");
        [lock unlock];
        return;
    }

    NSDebugLog(@"GSServiceDiscoveryManager: Restoring %lu services from state file", (unsigned long)[state count]);

    NSEnumerator *keyEnum = [state keyEnumerator];
    NSString *serviceKeyStr;

    while ((serviceKeyStr = [keyEnum nextObject])) {
        NSDictionary *serviceInfo = [state objectForKey:serviceKeyStr];
        GSServiceType serviceType = [serviceKeyStr intValue];
        NSNumber *portNum = [serviceInfo objectForKey:@"port"];

        if (portNum) {
            NSInteger port = [portNum intValue];
            NSDebugLog(@"GSServiceDiscoveryManager: Restoring service type %d on port %ld",
                  serviceType, (long)port);

            // Re-announce the service
            [self announceService:serviceType port:port txtRecord:nil];
        }
    }

    NSDebugLog(@"GSServiceDiscoveryManager: State restoration complete");
    [lock unlock];
}

@end
