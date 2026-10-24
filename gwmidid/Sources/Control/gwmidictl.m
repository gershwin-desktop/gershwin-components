/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */
/*
 * gwmidictl: talks to the running gwmidid of the current user, for
 * scripts, tests and the terminal.
 */
#import <Foundation/Foundation.h>
#import "GMDaemonControl.h"
#import "GMConfiguration.h"

/* One line per object, key=value, so both people and scripts can read it. */
static void printStatus(NSDictionary *st)
{
  printf("port-layer %s\n", [[st objectForKey: @"PortLayer"] UTF8String]);
  for (NSDictionary *s in [st objectForKey: GMKeySessions])
    {
      printf("session \"%s\" port=%s enabled=%s announce=%s policy=%s running=%s",
        [[s objectForKey: GMKeyName] UTF8String],
        [[[s objectForKey: GMKeyPort] description] UTF8String],
        [[s objectForKey: GMKeyEnabled] boolValue] ? "yes" : "no",
        [[s objectForKey: GMKeyAnnounce] boolValue] ? "yes" : "no",
        [[s objectForKey: GMKeyPolicy] UTF8String],
        [[s objectForKey: @"Running"] boolValue] ? "yes" : "no");
      if ([s objectForKey: @"MIDIPort"])
        printf(" midi=%s", [[s objectForKey: @"MIDIPort"] UTF8String]);
      if ([s objectForKey: @"Error"])
        printf(" error=\"%s\"", [[s objectForKey: @"Error"] UTF8String]);
      printf("\n");
      for (NSDictionary *p in [s objectForKey: @"Participants"])
        printf("  participant %s name=\"%s\" address=%s role=%s state=%s "
          "latency-ms=%.2f sent=%s received=%s gaps=%s\n",
          [[p objectForKey: @"Identifier"] UTF8String],
          [[p objectForKey: @"Name"] UTF8String],
          [[p objectForKey: @"Address"] UTF8String],
          [[p objectForKey: @"Role"] UTF8String],
          [[p objectForKey: @"State"] UTF8String],
          [[p objectForKey: @"LatencyMs"] doubleValue],
          [[[p objectForKey: @"PacketsSent"] description] UTF8String],
          [[[p objectForKey: @"PacketsReceived"] description] UTF8String],
          [[[p objectForKey: @"SequenceGaps"] description] UTF8String]);
    }
  for (NSDictionary *d in [st objectForKey: GMKeyDirectory])
    printf("directory \"%s\" host=%s port=%s\n",
      [[d objectForKey: GMKeyName] UTF8String],
      [[d objectForKey: GMKeyHost] UTF8String],
      [[[d objectForKey: GMKeyPort] description] UTF8String]);
  for (NSDictionary *d in [st objectForKey: @"Discovered"])
    printf("discovered \"%s\" host=%s port=%s addresses=%s\n",
      [[d objectForKey: GMKeyName] UTF8String],
      [[d objectForKey: @"HostName"] UTF8String],
      [[[d objectForKey: GMKeyPort] description] UTF8String],
      [[[d objectForKey: @"Addresses"] componentsJoinedByString: @","] UTF8String]);
  for (NSString *e in [st objectForKey: @"Errors"])
    printf("error \"%s\"\n", [e UTF8String]);
}

static void usage(void)
{
  fprintf(stderr,
    "usage: gwmidictl status [--plist]\n"
    "       gwmidictl add <name> <port> [anyone|directory|nobody]\n"
    "       gwmidictl remove <name>\n"
    "       gwmidictl policy <name> anyone|directory|nobody\n"
    "       gwmidictl connect <session> <directory name|service|host:port>\n"
    "       gwmidictl disconnect <session> <participant identifier>\n"
    "       gwmidictl directory [<name> <host> <port>]...\n");
  exit(2);
}

int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      NSArray *args = [[NSProcessInfo processInfo] arguments];
      NSString *cmd;
      id<GMDaemonControl> proxy;
      NSString *err = nil;

      if ([args count] < 2) usage();
      cmd = [args objectAtIndex: 1];
      proxy = (id<GMDaemonControl>)[NSConnection rootProxyForConnectionWithRegisteredName: GMDefaultsDomain
        host: @"" usingNameServer: [NSMessagePortNameServer sharedInstance]];
      if (proxy == nil)
        {
          fprintf(stderr, "gwmidictl: gwmidid is not running for this user\n");
          return 1;
        }
      [(NSDistantObject *)proxy setProtocolForProxy: @protocol(GMDaemonControl)];

      if ([cmd isEqual: @"status"] && [args count] == 2)
        {
          printStatus([proxy daemonStatus]);
          return 0;
        }
      else if ([cmd isEqual: @"status"] && [args count] == 3
        && [[args objectAtIndex: 2] isEqual: @"--plist"])
        {
          NSData *xml = [NSPropertyListSerialization
            dataFromPropertyList: [proxy daemonStatus]
                          format: NSPropertyListXMLFormat_v1_0
                errorDescription: NULL];
          fwrite([xml bytes], 1, [xml length], stdout);
          return 0;
        }
      else if ([cmd isEqual: @"add"] && ([args count] == 4 || [args count] == 5))
        {
          NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [args objectAtIndex: 2], GMKeyName, [args objectAtIndex: 3], GMKeyPort, nil];
          if ([args count] == 5) [d setObject: [args objectAtIndex: 4] forKey: GMKeyPolicy];
          err = [proxy addSession: d];
        }
      else if ([cmd isEqual: @"remove"] && [args count] == 3)
        err = [proxy removeSession: [args objectAtIndex: 2]];
      else if ([cmd isEqual: @"policy"] && [args count] == 4)
        {
          NSDictionary *s = nil;
          for (NSDictionary *d in [[proxy daemonStatus] objectForKey: GMKeySessions])
            if ([[d objectForKey: GMKeyName] isEqual: [args objectAtIndex: 2]]) s = d;
          if (s == nil)
            err = @"no such session";
          else
            {
              NSMutableDictionary *m = [s mutableCopy];
              [m setObject: [args objectAtIndex: 3] forKey: GMKeyPolicy];
              err = [proxy updateSession: [args objectAtIndex: 2] withConfiguration: m];
            }
        }
      else if ([cmd isEqual: @"connect"] && [args count] == 4)
        err = [proxy connectSession: [args objectAtIndex: 2] to: [args objectAtIndex: 3]];
      else if ([cmd isEqual: @"disconnect"] && [args count] == 4)
        err = [proxy disconnectParticipant: [args objectAtIndex: 3]
                                 inSession: [args objectAtIndex: 2]];
      else if ([cmd isEqual: @"directory"] && ([args count] - 2) % 3 == 0)
        {
          NSMutableArray *entries = [NSMutableArray array];
          NSUInteger i;
          for (i = 2; i < [args count]; i += 3)
            [entries addObject: @{ GMKeyName: [args objectAtIndex: i],
              GMKeyHost: [args objectAtIndex: i + 1],
              GMKeyPort: [args objectAtIndex: i + 2] }];
          err = [proxy setDirectoryEntries: entries];
        }
      else
        usage();

      if (err != nil)
        {
          fprintf(stderr, "gwmidictl: %s\n", [err UTF8String]);
          return 1;
        }
    }
  return 0;
}
