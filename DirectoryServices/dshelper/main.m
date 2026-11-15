#import <Foundation/Foundation.h>
#import "dshelper.h"
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/file.h>
#import <errno.h>
#import <string.h>

#define PID_FILE "/var/run/dshelper.pid"

static DSHelper *helper = nil;
static int pidFileFd = -1;

void signalHandler(int sig) {
    NSDebugLLog(@"gwcomp", @"dshelper: Received signal %d, shutting down...", sig);
    [helper unregisterService];
    [helper stopServer];
    if (pidFileFd >= 0) {
        flock(pidFileFd, LOCK_UN);
        close(pidFileFd);
    }
    unlink(PID_FILE);
    exit(0);
}

// Returns YES if we acquired the lock, NO if another instance is running
BOOL acquirePidLock(void) {
    // Open or create the PID file
    pidFileFd = open(PID_FILE, O_RDWR | O_CREAT, 0644);
    if (pidFileFd < 0) {
        fprintf(stderr, "dshelper: Cannot open %s: %s\n", PID_FILE, strerror(errno));
        return NO;
    }

    // Try to acquire an exclusive lock (non-blocking)
    if (flock(pidFileFd, LOCK_EX | LOCK_NB) < 0) {
        if (errno == EWOULDBLOCK) {
            // Another instance holds the lock - read its PID
            char buf[32];
            ssize_t n = read(pidFileFd, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = '\0';
                // Strip trailing newline
                char *nl = strchr(buf, '\n');
                if (nl) *nl = '\0';
                fprintf(stderr, "dshelper: Already running, PID %s\n", buf);
            } else {
                fprintf(stderr, "dshelper: Already running\n");
            }
        } else {
            fprintf(stderr, "dshelper: Cannot lock %s: %s\n", PID_FILE, strerror(errno));
        }
        close(pidFileFd);
        pidFileFd = -1;
        return NO;
    }

    return YES;
}

void writePid(void) {
    if (pidFileFd < 0) return;

    // Truncate and write our PID
    ftruncate(pidFileFd, 0);
    lseek(pidFileFd, 0, SEEK_SET);

    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%d\n", getpid());
    write(pidFileFd, buf, len);
}

void printUsage(const char *progname) {
    fprintf(stderr, "Usage: %s [-d] [-h]\n", progname);
    fprintf(stderr, "  -d    Run in foreground (debug mode)\n");
    fprintf(stderr, "  -h    Show this help\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Directory Services Helper - advertises a directory server\n");
    fprintf(stderr, "Runs only on a directory server (%s exists);\n",
            [DS_DOMAIN_PLIST UTF8String]);
    fprintf(stderr, "users and groups resolve through nss_gershwin without it.\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL foreground = NO;
        int opt;

        while ((opt = getopt(argc, argv, "dh")) != -1) {
            switch (opt) {
                case 'd':
                    foreground = YES;
                    break;
                case 'h':
                    printUsage(argv[0]);
                    return 0;
                default:
                    printUsage(argv[0]);
                    return 1;
            }
        }

        // Must run as root to read password hashes
        if (getuid() != 0) {
            fprintf(stderr, "dshelper: Must run as root\n");
            return 1;
        }

        // nss_gershwin reads the plists itself, so a standalone machine or a
        // client has nothing for dshelper to do. It is needed only on a
        // directory server, to advertise GershwinDirectory for dscli join.
        if (![[DSHelper sharedHelper] isServer]) {
            fprintf(stderr, "dshelper: Not a directory server (no %s); "
                            "nothing to do\n", [DS_DOMAIN_PLIST UTF8String]);
            return 0;
        }

        // Acquire PID file lock before forking to prevent race conditions
        if (!acquirePidLock()) {
            return 1;
        }

        // Daemonize unless -d flag
        if (!foreground) {
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork");
                return 1;
            }
            if (pid > 0) {
                // Parent exits - child inherits the lock
                printf("dshelper: Started with PID %d\n", pid);
                _exit(0);  // Use _exit to avoid flushing buffers twice
            }

            // Child continues
            setsid();
            chdir("/");

            // Write our PID to the locked file
            writePid();

            // Close standard file descriptors
            close(STDIN_FILENO);
            close(STDOUT_FILENO);
            close(STDERR_FILENO);
        } else {
            // Foreground mode - write PID now
            writePid();
        }

        // Set up signal handlers
        signal(SIGINT, signalHandler);
        signal(SIGTERM, signalHandler);
        signal(SIGPIPE, SIG_IGN);

        // Create directory if needed
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dirPath = @"/Local/Library/DirectoryServices";
        if (![fm fileExistsAtPath:dirPath]) {
            NSError *error = nil;
            [fm createDirectoryAtPath:dirPath
          withIntermediateDirectories:YES
                           attributes:@{
                               NSFilePosixPermissions: @0755,
                               NSFileOwnerAccountID: @0,
                               NSFileGroupOwnerAccountID: @0
                           }
                                error:&error];
            if (error) {
                NSDebugLLog(@"gwcomp", @"dshelper: Failed to create %@: %@", dirPath, error);
            }
        }

        // Start server
        helper = [DSHelper sharedHelper];

        NSDebugLLog(@"gwcomp", @"dshelper: Starting Directory Services Helper");

        // Register with port name server for discovery BEFORE starting
        // the blocking accept loop (servers only)
        [helper registerService];

        if (![helper startServer]) {
            NSDebugLLog(@"gwcomp", @"dshelper: Failed to start server");
            return 1;
        }

        return 0;
    }
}
