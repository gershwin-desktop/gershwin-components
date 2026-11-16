/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* BSD syslog pads a single-digit day with a second space ("Nov  8"); the
   parser must read that and "Nov 18" alike, and skip lines it cannot read. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "LogSource.h"

@interface SyslogLogSource (Parsing)
- (LogEntry *)parseLogLine:(NSString *)line;
@end

static NSDateComponents *Parts(LogEntry *entry)
{
    NSUInteger units = NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour
        | NSCalendarUnitMinute | NSCalendarUnitSecond;
    return [[NSCalendar currentCalendar] components:units fromDate:[entry timestamp]];
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    SyslogLogSource *source = [[SyslogLogSource alloc] initWithLogFilePath:@"/var/log/messages"];

    START_SET("single-digit day")
    LogEntry *e = [source parseLogLine:@"Nov  8 12:00:01 fbsd sshd[123]: Accepted publickey for root"];
    PASS(e != nil, "a padded single-digit day parses");
    NSDateComponents *c = Parts(e);
    PASS([c month] == 11 && [c day] == 8, "month and day are Nov 8");
    PASS([c hour] == 12 && [c minute] == 0 && [c second] == 1, "the time is 12:00:01");
    PASS_EQUAL([e process], @"sshd", "the process is read after the padded date");
    PASS([e pid] == 123, "the pid is read");
    PASS_EQUAL([e message], @"Accepted publickey for root", "the message is read");
    END_SET("single-digit day")

    START_SET("two-digit day")
    LogEntry *e = [source parseLogLine:@"Nov 18 23:59:58 fbsd kernel: em0: link state changed to UP"];
    PASS(e != nil, "a two-digit day parses");
    NSDateComponents *c = Parts(e);
    PASS([c month] == 11 && [c day] == 18, "month and day are Nov 18");
    PASS([c hour] == 23 && [c minute] == 59 && [c second] == 58, "the time is 23:59:58");
    PASS_EQUAL([e process], @"kernel", "a process without a pid is read");
    PASS([e pid] == 0, "no pid is zero");
    END_SET("two-digit day")

    START_SET("malformed lines")
    NSArray *bad = @[
        @"this is not a syslog line at all, just text",
        @"Xyz  8 12:00:01 fbsd sshd[1]: unknown month name here",
        @"Nov xx 12:00:01 fbsd sshd[1]: day is not a number",
        @"Nov  8 noon-ish fbsd sshd[1]: time is not a time",
        @"Nov                                                 ",
        @"short",
        @""
    ];
    for (NSString *line in bad)
      {
        LogEntry *e = nil;
        BOOL raised = NO;
        @try
          {
            e = [source parseLogLine:line];
          }
        @catch (NSException *x)
          {
            raised = YES;
          }
        PASS(!raised && e == nil, "a malformed line is skipped without an exception");
      }
    END_SET("malformed lines")

    [source release];
    [arp release];
    return 0;
}
