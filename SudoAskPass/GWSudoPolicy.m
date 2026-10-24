/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWSudoPolicy.h"

GWSudoPolicyAnswer GWSudoPolicyForPassword(NSString *password, NSString *sudoCommand)
{
  NSTask *task = [[NSTask alloc] init];
  NSPipe *input = [NSPipe pipe];
  NSPipe *errors = [NSPipe pipe];
  NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
  GWSudoPolicyAnswer answer = GWSudoPolicyUnknown;

  /* -S takes the password from stdin.  Without SUDO_ASKPASS this sudo can
     never start this askpass again; the C locale makes its messages
     comparable.  -k ignores cached credentials, so the password is really
     checked; -l only lists, it runs nothing. */
  [env removeObjectForKey: @"SUDO_ASKPASS"];
  [env setObject: @"C" forKey: @"LC_ALL"];
  [task setLaunchPath: sudoCommand];
  [task setArguments: [NSArray arrayWithObjects: @"-k", @"-S", @"-p", @"", @"-l", nil]];
  [task setEnvironment: env];
  [task setStandardInput: input];
  [task setStandardOutput: [NSFileHandle fileHandleWithNullDevice]];
  [task setStandardError: errors];
  [env release];

  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      [task release];
      return GWSudoPolicyUnknown;
    }

  NSFileHandle *in = [input fileHandleForWriting];
  [in writeData: [[password stringByAppendingString: @"\n"] dataUsingEncoding: NSUTF8StringEncoding]];
  [in closeFile];

  NSData *said = [[errors fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];

  if ([task terminationStatus] == 0)
    {
      answer = GWSudoPolicyAllowed;
    }
  else
    {
      NSString *text = [[[NSString alloc] initWithData: said encoding: NSUTF8StringEncoding] autorelease];

      /* the two ways sudo words "no rule allows you anything" */
      if ([text rangeOfString: @"may not run sudo"].location != NSNotFound
          || [text rangeOfString: @"is not in the sudoers file"].location != NSNotFound)
        answer = GWSudoPolicyRefused;
    }
  [task release];
  return answer;
}
