/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPermissionCheck.h"
#include <grp.h>
#include <pwd.h>
#include <unistd.h>
#include <sys/stat.h>

/* The group Linux distributions give scanner access to (libsane udev rules) */
static NSString * const SCLinuxScannerGroup = @"scanner";

/* Names of the groups this process has, i.e. those of the login session */
static NSArray *
SCSessionGroupNames(void)
{
  NSMutableArray *names = [NSMutableArray array];
  gid_t gids[NGROUPS_MAX + 1];
  int n = getgroups(NGROUPS_MAX, gids), i;

  if (n < 0)
    {
      n = 0;
    }
  gids[n++] = getegid();
  for (i = 0; i < n; i++)
    {
      struct group *g = getgrgid(gids[i]);

      if (g != NULL)
        {
          [names addObject: [NSString stringWithUTF8String: g->gr_name]];
        }
    }
  return names;
}

/* YES when /etc/group (or the user's primary group) lists the user */
static BOOL
SCGroupDatabaseLists(NSString *group, NSString *user)
{
  struct group *g = getgrnam([group UTF8String]);
  struct passwd *pw = getpwnam([user UTF8String]);
  char **m;

  if (g == NULL)
    {
      return NO;
    }
  if (pw != NULL && pw->pw_gid == g->gr_gid)
    {
      return YES;
    }
  for (m = g->gr_mem; m != NULL && *m != NULL; m++)
    {
      if (strcmp(*m, [user UTF8String]) == 0)
        {
          return YES;
        }
    }
  return NO;
}

static BOOL
SCCanReadWrite(NSString *path)
{
  return access([path fileSystemRepresentation], R_OK | W_OK) == 0;
}

@implementation SCPermissionCheck

+ (NSArray *) linuxScannerNodesInUdevData: (NSString *)udevDataDir
                                  devRoot: (NSString *)devRoot
{
  NSMutableArray *nodes = [NSMutableArray array];

  for (NSString *entry in [[NSFileManager defaultManager]
                            contentsOfDirectoryAtPath: udevDataDir error: NULL])
    {
      NSString *content;
      unsigned minor;

      /* c189:<minor> are USB device nodes; minor = (bus - 1) * 128 + device - 1 */
      if (![entry hasPrefix: @"c189:"])
        {
          continue;
        }
      content = [NSString stringWithContentsOfFile:
                   [udevDataDir stringByAppendingPathComponent: entry]
                                          encoding: NSUTF8StringEncoding
                                             error: NULL];
      if ([content rangeOfString: @"E:libsane_matched=yes"].location == NSNotFound)
        {
          continue;
        }
      minor = (unsigned)[[entry substringFromIndex: 5] intValue];
      [nodes addObject: [devRoot stringByAppendingPathComponent:
        [NSString stringWithFormat: @"bus/usb/%03u/%03u",
                  minor / 128 + 1, minor % 128 + 1]]];
    }
  return nodes;
}

+ (NSString *) adviceForGroup: (NSString *)group
                     userName: (NSString *)user
                inSessionGIDs: (NSArray *)sessionGroupNames
            inGroupDatabase: (BOOL)listedInGroupDatabase
{
  if ([sessionGroupNames containsObject: group])
    {
      return nil;
    }
  if (listedInGroupDatabase)
    {
      return [NSString stringWithFormat:
        @"You were added to the group \"%@\", but this session started before "
        @"that. Log out and log in again.", group];
    }
  return [NSString stringWithFormat:
    @"Your account \"%@\" is not in the group \"%@\". An administrator can "
    @"add it with \"sudo usermod -aG %@ %@\"; then log out and log in again.",
    user, group, group, user];
}

+ (NSString *) problemWithConnectedScanners
{
#if defined(__linux__)
  NSString *user = NSUserName();
  NSMutableArray *blocked = [NSMutableArray array];
  NSString *advice;

  if (geteuid() == 0)
    {
      return nil;
    }
  for (NSString *node in [self linuxScannerNodesInUdevData: @"/run/udev/data"
                                                    devRoot: @"/dev"])
    {
      if (!SCCanReadWrite(node))
        {
          [blocked addObject: node];
        }
    }
  if ([blocked count] == 0)
    {
      return nil;
    }
  advice = [self adviceForGroup: SCLinuxScannerGroup userName: user
                  inSessionGIDs: SCSessionGroupNames()
                inGroupDatabase: SCGroupDatabaseLists(SCLinuxScannerGroup, user)];
  if (advice == nil)
    {
      /* In the group, yet no access: the udev rule did not grant it */
      advice = [NSString stringWithFormat:
        @"%@ is not accessible to the group \"%@\" either; check that the "
        @"udev rules of sane-backends are installed, then reconnect the scanner.",
        [blocked objectAtIndex: 0], SCLinuxScannerGroup];
    }
  return [NSString stringWithFormat:
    @"A USB scanner is connected, but you cannot use it. %@", advice];
#else
  return nil;
#endif
}

+ (NSString *) problemWithUSBAccess
{
  NSString *user = NSUserName();

  if (geteuid() == 0)
    {
      return nil;
    }
#if defined(__linux__)
  {
    NSString *connected = [self problemWithConnectedScanners];

    if (connected != nil)
      {
        return connected;
      }
    /* Distributions without the group grant access differently; nothing to say */
    if (getgrnam([SCLinuxScannerGroup UTF8String]) == NULL)
      {
        return nil;
      }
    return [self adviceForGroup: SCLinuxScannerGroup userName: user
                  inSessionGIDs: SCSessionGroupNames()
                inGroupDatabase: SCGroupDatabaseLists(SCLinuxScannerGroup, user)];
  }
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \
  || defined(__DragonFly__)
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *sessionGroups = SCSessionGroupNames();

    /*
     * Every USB device has ugen nodes, so one this user cannot open is no
     * proof by itself; this is only asked when no scanner could be used
     */
    for (NSString *entry in [fm contentsOfDirectoryAtPath: @"/dev" error: NULL])
      {
        NSString *node = [@"/dev" stringByAppendingPathComponent: entry];
        struct stat st;
        struct group *g;
        NSString *group;

        if (![entry hasPrefix: @"ugen"] || SCCanReadWrite(node)
            || stat([node fileSystemRepresentation], &st) != 0)
          {
            continue;
          }
        g = getgrgid(st.st_gid);
        group = g ? [NSString stringWithUTF8String: g->gr_name]
                  : [NSString stringWithFormat: @"%u", (unsigned)st.st_gid];
        if ((st.st_mode & (S_IRGRP | S_IWGRP)) == (S_IRGRP | S_IWGRP))
          {
            NSString *advice = [self adviceForGroup: group userName: user
                                      inSessionGIDs: sessionGroups
                                    inGroupDatabase: SCGroupDatabaseLists(group, user)];

            if (advice != nil)
              {
                return [NSString stringWithFormat:
                  @"USB scanners need access to %@ and the other USB device "
                  @"nodes. %@", node, advice];
              }
            continue;
          }
        return [NSString stringWithFormat:
          @"USB scanners need read and write access to %@ and the other USB "
          @"device nodes, but only their owner may use them (mode %03o, group "
          @"\"%@\"). An administrator has to allow a group access, with devfs "
          @"rules on FreeBSD or the permissions of /dev/ugen* on OpenBSD, and "
          @"add your account to it.",
          node, (unsigned)(st.st_mode & 0777), group];
      }
    return nil;
  }
#else
  return nil;
#endif
}

@end
