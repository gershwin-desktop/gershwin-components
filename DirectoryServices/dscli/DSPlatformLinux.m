#import "DSPlatform.h"
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

@interface DSPlatformLinux : NSObject <DSPlatform>
@end

@implementation DSPlatformLinux

- (NSString *)platformName
{
    return @"Linux";
}

- (BOOL)isAvailable
{
#if defined(__linux__)
    return YES;
#else
    return NO;
#endif
}

#pragma mark - Helper Methods

- (BOOL)runCommand:(NSString *)command
{
    int result = system([command UTF8String]);
    return (result == 0);
}

- (BOOL)hasSystemd
{
    // Check for systemctl binary and running systemd (PID 1)
    struct stat st;
    if (stat("/run/systemd/system", &st) == 0) {
        return YES;
    }
    return NO;
}

- (BOOL)serviceEnable:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl enable %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"update-rc.d %@ defaults >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (BOOL)serviceStart:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl start %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"service %@ start >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (BOOL)serviceIsRunning:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl is-active %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"service %@ status >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (BOOL)serviceRestart:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl restart %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"service %@ restart >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (BOOL)serviceStop:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl stop %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"service %@ stop >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (BOOL)serviceDisable:(NSString *)service
{
    NSString *cmd;
    if ([self hasSystemd]) {
        cmd = [NSString stringWithFormat:@"systemctl disable %@ >/dev/null 2>&1", service];
    } else {
        cmd = [NSString stringWithFormat:@"update-rc.d %@ remove >/dev/null 2>&1", service];
    }
    return [self runCommand:cmd];
}

- (NSString *)readFile:(NSString *)path
{
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    return contents;
}

- (BOOL)writeFile:(NSString *)path contents:(NSString *)contents
{
    NSError *error = nil;
    return [contents writeToFile:path
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&error];
}

- (BOOL)appendToFile:(NSString *)path line:(NSString *)line
{
    NSString *contents = [self readFile:path];
    if (!contents) {
        contents = @"";
    }

    // Check if line already exists
    if ([contents rangeOfString:line].location != NSNotFound) {
        return YES; // Already present
    }

    // Ensure file ends with newline before appending
    if ([contents length] > 0 && ![contents hasSuffix:@"\n"]) {
        contents = [contents stringByAppendingString:@"\n"];
    }

    contents = [contents stringByAppendingFormat:@"%@\n", line];
    return [self writeFile:path contents:contents];
}

#pragma mark - Server (Promote) Operations

- (BOOL)configureNFSExports
{
    NSString *exportLine = @"/Local *(rw,no_root_squash,no_subtree_check,fsid=0)";
    NSString *exportsPath = @"/etc/exports";

    // Check if already configured
    NSString *contents = [self readFile:exportsPath];
    if (contents && [contents rangeOfString:@"/Local"].location != NSNotFound) {
        printf("NFS exports already configured for /Local\n");
        return YES;
    }

    if (![self appendToFile:exportsPath line:exportLine]) {
        fprintf(stderr, "Failed to update /etc/exports\n");
        return NO;
    }

    printf("Added /Local to NFS exports\n");
    return YES;
}

- (BOOL)enableNFSServer
{
    BOOL success = YES;

    if (![self serviceEnable:@"rpcbind"]) {
        fprintf(stderr, "Failed to enable rpcbind\n");
        success = NO;
    } else {
        printf("Enabled rpcbind\n");
    }

    if (![self serviceEnable:@"nfs-kernel-server"]) {
        fprintf(stderr, "Failed to enable nfs-server\n");
        success = NO;
    } else {
        printf("Enabled nfs-server\n");
    }

    return success;
}

- (BOOL)startNFSServer
{
    BOOL success = YES;

    // rpcbind: start if not running
    if ([self serviceIsRunning:@"rpcbind"]) {
        printf("rpcbind already running\n");
    } else if ([self serviceStart:@"rpcbind"]) {
        printf("Started rpcbind\n");
    } else {
        fprintf(stderr, "Failed to start rpcbind\n");
        success = NO;
    }

    // nfs-server: restart if running (to reload exports), otherwise start
    if ([self serviceIsRunning:@"nfs-kernel-server"]) {
        if ([self serviceRestart:@"nfs-kernel-server"]) {
            printf("Restarted nfs-server\n");
        } else {
            fprintf(stderr, "Failed to restart nfs-server\n");
            success = NO;
        }
    } else if ([self serviceStart:@"nfs-kernel-server"]) {
        printf("Started nfs-server\n");
    } else {
        fprintf(stderr, "Failed to start nfs-server\n");
        success = NO;
    }

    // Reload exports
    [self runCommand:@"exportfs -ra >/dev/null 2>&1"];

    return success;
}

- (BOOL)startDSHelper
{
    // Enable dshelper at boot and (re)start it so it registers with gdomap.
    // Under systemd gdomap is its own unit; the sysvinit script starts it.
    if ([self hasSystemd] && ![self serviceEnable:@"gdomap"]) {
        fprintf(stderr, "Failed to enable gdomap\n");
        return NO;
    }
    if (![self serviceEnable:@"dshelper"]) {
        fprintf(stderr, "Failed to enable dshelper\n");
        return NO;
    }
    if ([self serviceRestart:@"dshelper"]) {
        printf("Started dshelper (service now discoverable)\n");
        return YES;
    }
    fprintf(stderr, "Failed to start dshelper\n");
    return NO;
}

#pragma mark - Server (Demote) Operations

- (BOOL)removeNFSExports
{
    NSString *exportsPath = @"/etc/exports";
    NSString *contents = [self readFile:exportsPath];

    if (!contents) {
        return YES;
    }

    NSMutableArray *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL modified = NO;

    for (NSInteger i = [lines count] - 1; i >= 0; i--) {
        NSString *line = lines[i];
        if ([line rangeOfString:@"/Local"].location != NSNotFound) {
            [lines removeObjectAtIndex:i];
            modified = YES;
        }
    }

    if (modified) {
        NSString *newContents = [lines componentsJoinedByString:@"\n"];
        if (![self writeFile:exportsPath contents:newContents]) {
            fprintf(stderr, "Failed to update /etc/exports\n");
            return NO;
        }
        printf("Removed /Local from NFS exports\n");

        // Reload exports
        [self runCommand:@"exportfs -ra >/dev/null 2>&1"];
    }

    return YES;
}

- (BOOL)stopNFSServer
{
    // Stop nfs-server but leave rpcbind running (may be needed by other services)
    if ([self serviceStop:@"nfs-kernel-server"]) {
        printf("Stopped nfs-server\n");
    }

    return YES;
}

- (BOOL)unregisterService
{
    // Unregister GershwinDirectory from gdomap
    if ([self runCommand:@"/System/Library/Tools/gdomap -U GershwinDirectory -T tcp_gdo >/dev/null 2>&1"]) {
        printf("Unregistered GershwinDirectory from gdomap\n");
        return YES;
    }
    return NO;
}

- (BOOL)stopDSHelper
{
    [self serviceStop:@"dshelper"];
    if ([self serviceDisable:@"dshelper"]) {
        printf("Stopped and disabled dshelper\n");
        return YES;
    }
    fprintf(stderr, "Failed to disable dshelper\n");
    return NO;
}

#pragma mark - Client (Join) Operations

- (BOOL)enableNFSClient
{
    BOOL success = YES;

    if (![self serviceEnable:@"rpcbind"]) {
        fprintf(stderr, "Failed to enable rpcbind\n");
        success = NO;
    } else {
        printf("Enabled rpcbind\n");
    }

    // On Linux, NFS client support is typically via nfs-common (Debian/Devuan)
    // or nfs-utils (Arch). The service name varies but the mount itself
    // just needs the kernel module and rpcbind.
    return success;
}

- (BOOL)startNFSClient
{
    BOOL success = YES;

    // rpcbind: start if not running
    if ([self serviceIsRunning:@"rpcbind"]) {
        printf("rpcbind already running\n");
    } else if ([self serviceStart:@"rpcbind"]) {
        printf("Started rpcbind\n");
    } else {
        fprintf(stderr, "Failed to start rpcbind\n");
        success = NO;
    }

    return success;
}

- (BOOL)createNetworkMount:(NSString *)server
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    if (![fm fileExistsAtPath:@"/Network"]) {
        if (![fm createDirectoryAtPath:@"/Network"
           withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0755}
                                 error:&error]) {
            fprintf(stderr, "Failed to create /Network: %s\n",
                    [[error localizedDescription] UTF8String]);
            return NO;
        }
        printf("Created /Network\n");
    }

    return YES;
}

- (BOOL)addFstabEntry:(NSString *)server
{
    NSString *fstabLine = [NSString stringWithFormat:@"%@:/Local\t/Network\tnfs\trw\t0\t0", server];
    NSString *fstabPath = @"/etc/fstab";

    // Check if already configured
    NSString *contents = [self readFile:fstabPath];
    if (contents && [contents rangeOfString:@"/Network"].location != NSNotFound) {
        printf("fstab already configured for /Network\n");
        return YES;
    }

    if (![self appendToFile:fstabPath line:fstabLine]) {
        fprintf(stderr, "Failed to update /etc/fstab\n");
        return NO;
    }

    printf("Added %s:/Local -> /Network to fstab\n", [server UTF8String]);
    return YES;
}

- (BOOL)mountNetwork
{
    // Check if already mounted
    NSString *cmd = @"mount | grep '/Network' >/dev/null 2>&1";
    if ([self runCommand:cmd]) {
        printf("/Network already mounted\n");
        return YES;
    }

    if (![self runCommand:@"mount /Network"]) {
        fprintf(stderr, "Failed to mount /Network\n");
        return NO;
    }

    printf("Mounted /Network\n");
    return YES;
}

#pragma mark - Leave Operations

- (BOOL)unmountNetwork
{
    // Check if mounted
    NSString *cmd = @"mount | grep '/Network' >/dev/null 2>&1";
    if (![self runCommand:cmd]) {
        printf("/Network not mounted\n");
        return YES;
    }

    if (![self runCommand:@"umount /Network"]) {
        fprintf(stderr, "Failed to unmount /Network (may be in use)\n");
        return NO;
    }

    printf("Unmounted /Network\n");
    return YES;
}

- (BOOL)removeFstabEntry
{
    NSString *fstabPath = @"/etc/fstab";
    NSString *contents = [self readFile:fstabPath];

    if (!contents) {
        return YES;
    }

    NSMutableArray *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL modified = NO;

    for (NSInteger i = [lines count] - 1; i >= 0; i--) {
        NSString *line = lines[i];
        if ([line rangeOfString:@"/Network"].location != NSNotFound) {
            [lines removeObjectAtIndex:i];
            modified = YES;
        }
    }

    if (modified) {
        NSString *newContents = [lines componentsJoinedByString:@"\n"];
        if (![self writeFile:fstabPath contents:newContents]) {
            fprintf(stderr, "Failed to update /etc/fstab\n");
            return NO;
        }
        printf("Removed /Network from fstab\n");
    }

    return YES;
}

#pragma mark - Server Status

- (NSArray<NSString *> *)connectedClients
{
    // Query the kernel for live NFS connections (port 2049 ESTABLISHED).
    // /proc/net/tcp state 01 = ESTABLISHED; local port 0801 = 2049.
    // Prefer /proc parsing so this works without ss(8) installed.
    NSMutableSet<NSString *> *peers = [NSMutableSet set];

    FILE *fp = fopen("/proc/net/tcp", "r");
    if (fp) {
        char line[512];
        // Skip header
        if (fgets(line, sizeof(line), fp)) {
            while (fgets(line, sizeof(line), fp)) {
                // Format: sl local_addr:port rem_addr:port st ...
                char localHex[64], remHex[64];
                unsigned int state = 0;
                if (sscanf(line, "%*d: %63s %63s %x", localHex, remHex, &state) == 3) {
                    if (state != 0x01) continue; // ESTABLISHED only
                    char *lcolon = strchr(localHex, ':');
                    if (!lcolon) continue;
                    unsigned int lport = (unsigned int)strtoul(lcolon + 1, NULL, 16);
                    if (lport != 2049) continue;
                    char *rcolon = strchr(remHex, ':');
                    if (!rcolon) continue;
                    *rcolon = '\0';
                    unsigned int a1, a2, a3, a4;
                    if (sscanf(remHex, "%2x%2x%2x%2x", &a4, &a3, &a2, &a1) == 4) {
                        NSString *ip = [NSString stringWithFormat:@"%u.%u.%u.%u",
                                        a1, a2, a3, a4];
                        [peers addObject:ip];
                    }
                }
            }
        }
        fclose(fp);
    }

    // Also check /proc/net/tcp6 for IPv4-mapped and IPv6 peers on port 2049.
    FILE *fp6 = fopen("/proc/net/tcp6", "r");
    if (fp6) {
        char line[512];
        if (fgets(line, sizeof(line), fp6)) {
            while (fgets(line, sizeof(line), fp6)) {
                char localHex[128], remHex[128];
                unsigned int state = 0;
                if (sscanf(line, "%*d: %127s %127s %x", localHex, remHex, &state) == 3) {
                    if (state != 0x01) continue;
                    char *lcolon = strrchr(localHex, ':');
                    if (!lcolon) continue;
                    unsigned int lport = (unsigned int)strtoul(lcolon + 1, NULL, 16);
                    if (lport != 2049) continue;
                    char *rcolon = strrchr(remHex, ':');
                    if (!rcolon) continue;
                    *rcolon = '\0';
                    // Address is 32 hex chars. IPv4-mapped ends with ffff then 4 bytes.
                    size_t len = strlen(remHex);
                    if (len >= 8) {
                        const char *last8 = remHex + len - 8;
                        unsigned int a1, a2, a3, a4;
                        if (sscanf(last8, "%2x%2x%2x%2x", &a4, &a3, &a2, &a1) == 4) {
                            // Only treat as IPv4 if the preceding bytes look like ::ffff:
                            if (len == 32) {
                                char prefix[25];
                                strncpy(prefix, remHex, 24);
                                prefix[24] = '\0';
                                if (strcasecmp(prefix, "0000000000000000FFFF0000") == 0) {
                                    NSString *ip = [NSString stringWithFormat:@"%u.%u.%u.%u",
                                                    a1, a2, a3, a4];
                                    [peers addObject:ip];
                                    continue;
                                }
                            }
                            // Otherwise, leave IPv6 formatting to a future improvement.
                        }
                    }
                }
            }
        }
        fclose(fp6);
    }

    return [[peers allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark - Discovery

- (NSString *)discoverDirectoryServer
{
    printf("Searching for directory server...\n");

    // Generate interface config for gdomap
    // Use 'ip' command (iproute2) which is standard on all modern Linux distros
    // Falls back to ifconfig if ip is not available
    const char *ifaceConf = "/tmp/gdomap-iface.conf";
    FILE *ifp = popen(
        "if command -v ip >/dev/null 2>&1; then "
        "  ip -4 addr show scope global | awk '"
        "    /inet / { "
        "      split($2, a, \"/\"); addr = a[1]; cidr = a[2]+0; "
        "      m = 0; for (b = 0; b < 32; b++) { if (b < cidr) m += 2^(31-b) } "
        "      m1 = int(m / 2^24) % 256; m2 = int(m / 2^16) % 256; "
        "      m3 = int(m / 2^8) % 256; m4 = int(m) % 256; "
        "      mask = m1 \".\" m2 \".\" m3 \".\" m4; "
        "      bcast = \"0.0.0.0\"; "
        "      for (i = 1; i <= NF; i++) { if ($i == \"brd\") bcast = $(i+1) } "
        "      print addr, mask, bcast "
        "    }'; "
        "else "
        "  ifconfig -a 2>/dev/null | awk '"
        "    /^[a-z]/ { iface = $1 } "
        "    /inet / && !/127\\.0\\.0\\.1/ { "
        "      addr = $2; mask = \"\"; bcast = \"\"; "
        "      for (i = 1; i <= NF; i++) { "
        "        if ($i == \"netmask\") mask = $(i+1); "
        "        if ($i == \"broadcast\") bcast = $(i+1) "
        "      } "
        "      if (addr && mask) { "
        "        if (mask ~ /^0x/) { "
        "          cmd = \"printf \\\"%d.%d.%d.%d\\\" 0x\" substr(mask,3,2) \" 0x\" substr(mask,5,2) \" 0x\" substr(mask,7,2) \" 0x\" substr(mask,9,2); "
        "          cmd | getline mask; close(cmd) "
        "        } "
        "        print addr, mask, (bcast ? bcast : \"0.0.0.0\") "
        "      } "
        "    }'; "
        "fi", "r");
    if (ifp) {
        FILE *conf = fopen(ifaceConf, "w");
        if (conf) {
            char buf[256];
            while (fgets(buf, sizeof(buf), ifp)) {
                fputs(buf, conf);
            }
            fclose(conf);
        }
        pclose(ifp);
    }

    // Use gdomap to lookup the GershwinDirectory service
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "/System/Library/Tools/gdomap -a %s -L GershwinDirectory -T tcp_gdo -M '*' 2>/dev/null",
        ifaceConf);

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        unlink(ifaceConf);
        return nil;
    }

    char buffer[512];
    NSString *result = nil;

    while (fgets(buffer, sizeof(buffer), fp)) {
        // gdomap output: "Found GershwinDirectory on '<ip>' port <port>"
        NSString *line = [NSString stringWithUTF8String:buffer];

        // Look for "Found" pattern
        NSRange foundRange = [line rangeOfString:@"Found "];
        if (foundRange.location != NSNotFound) {
            // Extract IP from 'x.x.x.x'
            NSRange quoteStart = [line rangeOfString:@"'"];
            if (quoteStart.location != NSNotFound) {
                NSUInteger start = quoteStart.location + 1;
                NSRange quoteEnd = [line rangeOfString:@"'" options:0
                                                 range:NSMakeRange(start, [line length] - start)];
                if (quoteEnd.location != NSNotFound) {
                    NSString *addr = [line substringWithRange:
                        NSMakeRange(start, quoteEnd.location - start)];
                    if ([addr length] > 0) {
                        printf("Found directory server: %s\n", [addr UTF8String]);
                        result = addr;
                        break;
                    }
                }
            }
        }
    }

    pclose(fp);
    unlink(ifaceConf);
    return result;
}

@end
