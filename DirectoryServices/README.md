# Gershwin Directory Services

NSS module, management CLI and directory-server helper for users and groups kept in plist files.

## Components

- **nss_gershwin** - NSS module (`/System/Library/Libraries/nss_gershwin.so.1` on FreeBSD, `libnss_gershwin.so.2` on Linux). Reads the plists itself, so users and groups resolve with no daemon running.
- **dscli** - User and group management CLI (`/System/Library/Tools/dscli`)
- **dshelper** - Directory server helper (`/System/Library/Tools/dshelper`). Runs only on a directory server, where it advertises the server so clients can find it with `dscli join`.

## Linux Packages

### Devuan (sysvinit)

```sh
# Optional (client/server mode only)
apt install rpcbind nfs-kernel-server nfs-common
```

### Arch Linux (systemd)

```sh
# Optional (client/server mode only)
pacman -S rpcbind nfs-utils
```

### Notes

- `rpcbind` is not needed by nss_gershwin, dshelper or gdomap; it is only needed for NFS, i.e. client/server mode (`dscli promote`, `dscli join`), which fails if it is missing
- NFS packages are only needed for client/server mode (`dscli promote`, `dscli join`). Local-only accounts (`dscli init`, `dscli user add`, etc.) work without them
- On Arch, `nfs-utils` provides both server and client functionality (no separate `nfs-common`)
- On Devuan, `nfs-kernel-server` pulls in `nfs-common` automatically
- The implementation auto-detects systemd vs sysvinit at runtime, so the same binary works on both Devuan and Arch without recompilation

## Building

```sh
. /System/Library/Makefiles/GNUstep.sh
gmake
sudo -E gmake install
```

## Services

Local users need no service: nss_gershwin reads the plists in every process
that looks up a user or group, so login, `sudo` and `id` keep working even if
no daemon is running.

dshelper is needed only on a directory server. `dscli promote` enables and
starts it, and `dscli demote` stops and disables it, so there is normally
nothing to set up by hand. Its service does nothing on a machine that is not
a directory server (no `Domain.plist`): the rc and init scripts skip it, the
systemd unit has `ConditionPathExists`, and the binary exits.

| Platform | Enable | Start |
|----------|--------|-------|
| FreeBSD | `sudo sysrc dshelper_enable=YES` | `sudo service dshelper start` |
| Linux (sysvinit) | `sudo update-rc.d dshelper defaults` | `sudo service dshelper start` |
| Linux (systemd) | `sudo systemctl enable gdomap dshelper` | `sudo systemctl start gdomap dshelper` |

**Note:** dshelper requires **gdomap** (GNUstep Distributed Objects name server) to advertise the server. On FreeBSD and Linux sysvinit, gdomap is bundled with the dshelper service and starts/stops automatically. On Linux systemd, gdomap runs as a separate service unit, which `dscli promote` enables too.

## Quick Start

```sh
dscli init
dscli user add jsmith --realname "John Smith" --admin
dscli passwd jsmith

# Verify
getent passwd jsmith
id jsmith
```

**Note:** These commands must be run as root. After creating an admin user, if sudo is installed, you can use `sudo` for subsequent operations.

## Server Setup

To share users with clients over NFS:

```sh
# Complete quick start first, then:
sudo dscli promote

# Verify
showmount -e localhost
```

This configures NFS exports, starts NFS services, creates `Domain.plist`, and enables and starts dshelper, which registers the `GershwinDirectory` service with gdomap for client auto-discovery.

Only one directory server is allowed per network. The promote command checks for existing servers and prevents duplicates.

## Client Setup

To use users from a directory server:

```sh
sudo dscli init
sudo dscli join

# Verify
getent passwd jsmith
```

The `join` command auto-discovers directory servers on the network. A client does not run dshelper: once `/Network` is mounted, nss_gershwin reads the server's plists from it.

## Managing Users from Clients

Since the user database is shared over NFS, admin users can manage accounts from any client machine:

```sh
sudo dscli user add newuser --realname "New User" --admin
sudo dscli passwd newuser
sudo dscli user delete olduser
```

Changes are written directly to the server's plist files via the NFS mount and take effect immediately across all machines.

## Leaving the Directory

To disconnect from a directory server:

```sh
sudo dscli leave
```

This unmounts `/Network` and removes the server entry from `/etc/fstab`.

If a directory server goes offline permanently, all clients must run `dscli leave` before a new server can be promoted.

## Demoting the Server

To stop being a directory server:

```sh
sudo dscli demote
```

This unregisters the service from gdomap (so clients can no longer discover it), removes `Domain.plist`, stops and disables dshelper, stops NFS services, and removes `/Local` from NFS exports.

All clients must run `dscli leave` before a server can be demoted.

## dscli Reference

### User Commands

```sh
dscli user list                     # List all users
dscli user show <username>          # Show user details
dscli user add <username> [options] # Add a new user
dscli user delete <username>        # Delete a user
dscli user passwd <username>        # Set user password
dscli user edit <username> [options] # Modify user attributes
```

Options for `user add` and `user edit`:
```
--uid <uid>           User ID (auto-assigned if omitted)
--gid <gid>           Primary group ID (auto-assigned if omitted)
--realname <name>     Real name / GECOS field
--shell <shell>       Login shell (default: /bin/sh)
--admin               Add user to admin group
```

Options for `user passwd`:
```
--no-prompt           Read password from stdin (for scripts)
```

Example scripted password change:
```sh
echo "secret123" | dscli passwd jsmith --no-prompt
```

### Group Commands

```sh
dscli group list                        # List all groups
dscli group show <groupname>            # Show group details
dscli group add <groupname> [--gid N]   # Add a new group
dscli group delete <groupname>          # Delete a group
dscli group addmember <group> <user>    # Add user to group
dscli group removemember <group> <user> # Remove user from group
```

### Other Commands

```sh
dscli list              # List all users, groups, and status
dscli init              # Initialize directory structure
dscli promote           # Promote to directory server
dscli demote            # Demote from directory server
dscli join              # Join a directory (auto-discovers)
dscli leave             # Leave a directory
dscli passwd <username> # Set password (alias for user passwd)
dscli verify <username> # Verify user can authenticate
```

The `list` command provides a comprehensive overview:
- **Role**: Server, Client, or Standalone
- **Connected Clients**: (on server) machines with active NFS mounts
- **Connected Server**: (on client) which server this machine is joined to
- **Users**: All users sorted by UID
- **Groups**: All groups sorted by GID

## dshelper Reference

```sh
dshelper      # Run as daemon (background)
dshelper -d   # Run in foreground (debug mode)
```

dshelper exits at once on a machine that is not a directory server.

## How It Works

### Data Files

nss_gershwin checks for plists in this order, on every lookup:
1. `/Network/Library/DirectoryServices/` (client with server mounted)
2. `/Local/Library/DirectoryServices/` (server or standalone)

### Machine Roles

| Machine | /Network mounted? | Domain.plist exists? | nss_gershwin reads from | dshelper |
|---------|-------------------|---------------------|-------------------------|----------|
| Server | No | Yes | /Local | runs |
| Client | Yes | No | /Network | not needed |
| Standalone | No | No | /Local | not needed |

A missing or unparsable plist makes the `gershwin` source unavailable, and
the next source in `nsswitch.conf` (`files`) answers, so local system
accounts always resolve.

## Service Discovery

Directory servers are discovered automatically using GNUstep's network services API.

### Server Registration

When dshelper starts on a server (where `Domain.plist` exists), it registers itself with the network portmapper:

```objc
NSSocketPortNameServer *ns = [NSSocketPortNameServer sharedInstance];
NSSocketPort *port = [NSSocketPort portWithNumber:4721
                                           onHost:nil
                                     forceAddress:nil
                                         listener:YES];
[ns registerPort:port forName:@"GershwinDirectory"];
```

- **NSSocketPortNameServer** provides network-wide name registration via gdomap
- **NSSocketPort** creates a TCP listener socket on port 4721
- `registerPort:forName:` binds the name "GershwinDirectory" to this port across the network

### Client Discovery

When a client runs `dscli join`, it searches for registered servers:

```objc
NSSocketPortNameServer *ns = [NSSocketPortNameServer sharedInstance];
NSPort *port = [ns portForName:@"GershwinDirectory" onHost:@"*"];
```

- `portForName:onHost:` with host `@"*"` broadcasts a lookup across the local network
- Returns the port registered by the server, or nil if no server is found

### Getting the Server Hostname

Once discovered, the server's address is resolved to a hostname:

```objc
NSSocketPort *socketPort = (NSSocketPort *)port;
NSString *address = [socketPort address];  // IP address string
NSHost *remoteHost = [NSHost hostWithAddress:address];
NSString *hostname = [remoteHost name];    // DNS hostname
```

- **NSSocketPort** `-address` returns the server's IP address as a string
- **NSHost** `-hostWithAddress:` creates a host object from an IP
- **NSHost** `-name` performs reverse DNS lookup to get the hostname

This allows clients to discover and connect to directory servers without manual configuration.

## Authentication

Directory Services uses plist files instead of traditional Unix configuration files (`/etc/passwd`, `/etc/group`, `/etc/shadow`). This separation keeps directory-managed users distinct from local system accounts.

On the server, user and group plists are stored in `/Local/Library/DirectoryServices/`. When clients join the directory, the server's `/Local` is NFS-mounted at `/Network` on the client. nss_gershwin reads from `/Network/Library/DirectoryServices/` when the mount is present, giving clients access to the same user database as the server.

The **nss_gershwin** NSS module integrates with the system's name service switch. When configured in `/etc/nsswitch.conf`:

```
passwd: gershwin files
group:  gershwin files
```

The system looks up directory users first, then falls back to local files (`/etc/passwd`, `/etc/group`). This allows directory accounts to take precedence while still supporting local system accounts.

Authentication works through standard `pam_unix`. nss_gershwin returns password hashes only to root callers, matching FreeBSD's `/etc/master.passwd` security model. No PAM configuration changes are required—pam_unix automatically uses NSS to resolve users, so directory users authenticate seamlessly. SudoAskPass, which runs as the user, checks a directory user's password against the plist itself.

## Admin Access

Members of the `admin` group (gid 5000) are automatically nested into `wheel` and `sudo` groups if they exist on the system: both appear in the user's group list, and `getent group wheel` / `getent group sudo` list the admins next to the members in `/etc/group`. This enables `su` access on FreeBSD (wheel) and sudo access on Linux (sudo group).

The `dscli init` command automatically configures sudo for Gershwin tools and the admin group:

| Platform | Sudoers File |
|----------|--------------|
| FreeBSD/GhostBSD | `/usr/local/etc/sudoers.d/gershwin` |
| Linux | `/etc/sudoers.d/gershwin` |

The generated sudoers file contains:

1. **`secure_path`** - Set to root's PATH with GNUstep Tools paths prepended. This allows `sudo dscli` and other GNUstep commands to work without specifying full paths. The PATH is captured dynamically by sourcing `GNUstep.sh` at init time.

2. **`env_keep`** - Preserves GNUstep environment variables (`LD_LIBRARY_PATH`, `GNUSTEP_MAKEFILES`, etc.) so that GNUstep tools can find their libraries when run via sudo.

3. **`%admin ALL = (ALL) ALL`** - Grants admin group members full sudo privileges.

Example generated file:
```
# Gershwin Directory Services sudoers configuration
# Generated by dscli init - do not edit manually

Defaults secure_path="/root/Library/Tools:/Local/Library/Tools:/Network/Library/Tools:/System/Library/Tools:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin"
Defaults env_keep += "LD_LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH GNUSTEP_MAKEFILES GNUSTEP_USER_ROOT GNUSTEP_LOCAL_ROOT GNUSTEP_NETWORK_ROOT GNUSTEP_SYSTEM_ROOT LIBRARY_COMBO GNUSTEP_HOST GNUSTEP_HOST_CPU GNUSTEP_HOST_OS GNUSTEP_HOST_VENDOR"

%admin ALL = (ALL) ALL
```

The directory structure is created even if sudo is not yet installed, so sudo will work automatically once installed.

## Plist Fields

### User Fields

| Field | Required | Description |
|-------|----------|-------------|
| username | yes | Login name |
| uid | yes | User ID |
| gid | yes | Primary group ID |
| realName | no | GECOS field |
| shell | no | Login shell (default: /usr/sbin/nologin) |
| passwordHash | yes* | SHA-512 hash (*for login) |

Home directory is derived automatically: `/Local/Users/<username>` on server, `/Network/Users/<username>` on client.

### Group Fields

| Field | Required | Description |
|-------|----------|-------------|
| groupname | yes | Group name |
| gid | yes | Group ID |
| members | no | Array of usernames |

## Troubleshooting

Test NSS lookups:

```sh
getent passwd testuser
id testuser
sudo getent passwd testuser   # as root, the password field is the hash
```

If a directory user does not resolve, check that `/etc/nsswitch.conf` has
`passwd: gershwin files` and `group: gershwin files`, and that the plist
parses (`plparse Users.plist`): an unparsable plist
makes the module step aside for `files`.

The module's own tests run on the build host, with no nsswitch involved:

```sh
cd nss_gershwin && gmake check
```

On a directory server, run dshelper in foreground mode to see debug output:

```sh
sudo dshelper -d
```

## Developer Guide

### Platform Backends

The `dscli promote`, `demote`, `join`, and `leave` commands use platform-specific backends to configure NFS and network mounts. Backends are defined in `dscli/` with a protocol and per-platform implementations.

**DSPlatform.h** defines the protocol:

```objc
@protocol DSPlatform <NSObject>
- (NSString *)platformName;
- (BOOL)isAvailable;

// Server (promote) operations
- (BOOL)configureNFSExports;
- (BOOL)enableNFSServer;
- (BOOL)startNFSServer;
- (BOOL)restartDSHelper;

// Server (demote) operations
- (BOOL)removeNFSExports;
- (BOOL)stopNFSServer;
- (BOOL)unregisterService;

// Client (join) operations
- (BOOL)enableNFSClient;
- (BOOL)startNFSClient;
- (BOOL)createNetworkMount:(NSString *)server;
- (BOOL)addFstabEntry:(NSString *)server;
- (BOOL)mountNetwork;

// Client (leave) operations
- (BOOL)unmountNetwork;
- (BOOL)removeFstabEntry;

// Discovery
- (NSString *)discoverDirectoryServer;
@end
```

**Current implementations:**

| File | Platform | Status |
|------|----------|--------|
| DSPlatformFreeBSD.m | FreeBSD | Complete |
| DSPlatformLinux.m | Linux | Complete |

The factory function `DSPlatformCreate()` returns the appropriate backend based on compile-time platform detection. The Linux backend auto-detects systemd vs sysvinit at runtime.

### Adding a New Backend

1. Create `DSPlatform<Name>.m` implementing the `DSPlatform` protocol
2. Update `DSPlatform.m` to return your backend for the appropriate platform
3. Implement all required methods for NFS server/client configuration

Example for a new platform:

```objc
// DSPlatformNetBSD.m
#import "DSPlatform.h"

@interface DSPlatformNetBSD : NSObject <DSPlatform>
@end

@implementation DSPlatformNetBSD

- (NSString *)platformName { return @"NetBSD"; }
- (BOOL)isAvailable { return YES; }

- (BOOL)configureNFSExports {
    // Add /Local to /etc/exports
    // NetBSD-specific format
}

// ... implement remaining methods

@end
```

