/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCIPPUSB.h"
#import <PackageManager/GWSudoHelper.h>

static NSString *
SCReadAttribute(NSString *dir, NSString *name)
{
  NSString *s = [NSString stringWithContentsOfFile:
                   [dir stringByAppendingPathComponent: name]
                                          encoding: NSUTF8StringEncoding
                                             error: NULL];

  return [s stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL
SCIsIPPInterface(NSString *interfaceDir, NSString *deviceDir)
{
  NSString *c = SCReadAttribute(interfaceDir, @"bInterfaceClass");
  NSString *s = SCReadAttribute(interfaceDir, @"bInterfaceSubClass");
  NSString *p = SCReadAttribute(interfaceDir, @"bInterfaceProtocol");

  if ([c isEqualToString: @"07"] && [s isEqualToString: @"01"]
      && [p isEqualToString: @"04"])
    {
      return YES;
    }
  return [SCReadAttribute(deviceDir, @"idVendor") isEqualToString: @"03f0"]
    && [c isEqualToString: @"ff"] && [s isEqualToString: @"09"]
    && [p isEqualToString: @"01"];
}

@implementation SCIPPUSB

+ (NSArray *) deviceNamesInSysfs: (NSString *)root
{
  NSMutableArray *names = [NSMutableArray array];
  NSMutableSet *devices = [NSMutableSet set];

  for (NSString *entry in [[NSFileManager defaultManager]
                            contentsOfDirectoryAtPath: root error: NULL])
    {
      NSString *dir = [root stringByAppendingPathComponent: entry];
      NSRange colon = [entry rangeOfString: @":"];
      NSString *device, *deviceDir, *maker, *product, *name;

      /* Interfaces are "<device>:<config>.<interface>" next to their device */
      if (colon.location == NSNotFound)
        {
          continue;
        }
      device = [entry substringToIndex: colon.location];
      if (!SCIsIPPInterface(dir, [root stringByAppendingPathComponent: device]))
        {
          continue;
        }
      if ([devices containsObject: device])
        {
          continue;
        }
      [devices addObject: device];
      deviceDir = [root stringByAppendingPathComponent: device];
      maker = SCReadAttribute(deviceDir, @"manufacturer");
      product = SCReadAttribute(deviceDir, @"product");
      if ([product length] == 0)
        {
          name = @"USB printer";
        }
      else if ([maker length] > 0 && ![product hasPrefix: maker])
        {
          name = [NSString stringWithFormat: @"%@ %@", maker, product];
        }
      else
        {
          name = product;
        }
      [names addObject: name];
    }
  return names;
}

+ (NSArray *) connectedDeviceNames
{
#if defined(__linux__)
  return [self deviceNamesInSysfs: @"/sys/bus/usb/devices"];
#else
  /* The BSDs need root to read USB descriptors (usbconfig) */
  return @[];
#endif
}

+ (NSString *) programPath
{
  NSFileManager *fm = [NSFileManager defaultManager];

  /* Package managers put it in sbin, which a user's PATH often lacks */
  for (NSString *dir in @[@"/usr/sbin", @"/usr/bin", @"/usr/local/sbin",
                          @"/usr/local/bin", @"/usr/pkg/sbin"])
    {
      NSString *path = [dir stringByAppendingPathComponent: @"ipp-usb"];

      if ([fm isExecutableFileAtPath: path])
        {
          return path;
        }
    }
  return nil;
}

+ (BOOL) isRunningInProc: (NSString *)proc
{
  for (NSString *entry in [[NSFileManager defaultManager]
                            contentsOfDirectoryAtPath: proc error: NULL])
    {
      if ([entry intValue] > 0
          && [SCReadAttribute([proc stringByAppendingPathComponent: entry], @"comm")
               isEqualToString: @"ipp-usb"])
        {
          return YES;
        }
    }
  return NO;
}

+ (BOOL) isRunning
{
#if defined(__linux__)
  return [self isRunningInProc: @"/proc"];
#else
  return NO;
#endif
}

+ (void) startWithCompletion: (void (^)(BOOL running))completion
{
  NSString *program = [self programPath];
  NSArray *arguments = nil;
  NSString *launch;
  NSTask *task;

  if (program == nil)
    {
      completion(NO);
      return;
    }
  launch = GWSudoCommand(program, @[@"udev"], &arguments);
  task = [NSTask new];
  [task setLaunchPath: launch];
  [task setArguments: arguments];
  [task setStandardInput: [NSFileHandle fileHandleWithNullDevice]];
  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      completion(NO);
      return;
    }
  /*
   * It keeps running while devices are connected; the password prompt and
   * the device setup take a moment, after which it is either running or
   * has ended (wrong password, no device)
   */
  [self performSelector: @selector(reportStart:)
             withObject: @{@"task": task, @"completion": [completion copy]}
             afterDelay: 0.5];
}

+ (void) reportStart: (NSDictionary *)state
{
  NSTask *task = [state objectForKey: @"task"];
  void (^completion)(BOOL) = [state objectForKey: @"completion"];
  NSNumber *tries = [state objectForKey: @"tries"];

  if ([self isRunning] && [tries intValue] >= 4)
    {
      /* Give it two seconds to announce the devices to the network side */
      completion(YES);
      return;
    }
  if (![task isRunning])
    {
      completion([self isRunning]);
      return;
    }
  /* sudo still waits for the password, or ipp-usb is starting up */
  if ([tries intValue] > 240)
    {
      completion([self isRunning]);
      return;
    }
  [self performSelector: @selector(reportStart:)
             withObject: @{@"task": task, @"completion": completion,
                           @"tries": @([tries intValue] + 1)}
             afterDelay: 0.5];
}

@end
