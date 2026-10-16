/* t_SWRunGuard.m - ObjectTesting coverage for the run guard.
 *
 * Two halves, because there are two different things to get wrong:
 *
 *  1. The classification, fed synthetic listings. The dangerous line is the
 *     `sudo -A -E <exe> --rebuild ...` wrapper: it carries our executable path
 *     AND one of our flags, and it is an ancestor of the helper in every single
 *     run. Matching it would refuse every rebuild ever. The windowed app is
 *     nearly as bad - same executable, no flag.
 *
 *  2. The real thing: a real second process whose command line is exactly the
 *     shape of a competing run. A synthetic listing proves the decision; it
 *     cannot prove that ps was asked in a way this operating system answers.
 *     The guard reads ps through a ladder of invocations precisely because ps
 *     is procps on Linux and a 4.4BSD descendant on every BSD, and this case
 *     is what catches a spelling that works on the machine you tested on and
 *     nowhere else.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SWRunGuard.h"
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

// The executable under test. The decoy in part 2 is a second copy of THIS
// binary invoked with a run flag, so its command line is
// "<this path> --rebuild <...>" - indistinguishable, to the guard, from a
// competing Software Update run.
static NSString *gSelfExecutable = nil;

// Where the decoy records its pid, so a run that was killed part-way cannot
// leave one sleeping and make the NEXT run of this test fail for the wrong
// reason. The decoy outlives an assertion failure by design, so without this
// the suite would be order-dependent: a standalone run passes, a run in a
// loop fails, and the failure looks like a portability bug in ps.
static NSString *decoyPIDPath(void)
{
  return [NSTemporaryDirectory() stringByAppendingPathComponent:@"sw-guard-decoy.pid"];
}

static void killStaleDecoy(void)
{
  NSString *path = decoyPIDPath();
  NSString *pidText = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
  if ([pidText length] == 0) return;
  int pid = [pidText intValue];
  if (pid > 0) kill((pid_t)pid, SIGKILL);
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static NSString *line(pid_t pid, NSString *command)
{
  return [NSString stringWithFormat:@"%d %@", (int)pid, command];
}

static BOOL rejects(NSString *listing, NSString *executable)
{
  return [SWRunGuard rejectListing:listing executable:executable selfPID:4242 reason:NULL];
}

int main(int argc, const char **argv)
{
  // Decoy mode. Set only by the test below, and only so that a second copy of
  // this binary can sit in the process table looking exactly like a competing
  // run without doing any work.
  if (getenv("SW_TEST_DECOY") != NULL && argc >= 2 &&
      (strcmp(argv[1], "--rebuild") == 0 || strcmp(argv[1], "--run-update") == 0)) {
    [[NSString stringWithFormat:@"%d", (int)getpid()]
      writeToFile:decoyPIDPath() atomically:YES
        encoding:NSUTF8StringEncoding error:NULL];
    sleep(120);
    return 0;
  }

  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  killStaleDecoy();
  gSelfExecutable = [[NSBundle mainBundle] executablePath];

  // The synthetic half uses an arbitrary path so the expected command lines are
  // readable; the guard's real behaviour is identical for any prefix.
  NSString *exe = @"/System/Applications/Utilities/SoftwareUpdate.app/SoftwareUpdate";

  /* --- 1. the classification, over synthetic listings --- */

  PASS(!rejects(line(4242, @"--rebuild /tmp/SoftwareUpdate-run-4242.plist"), exe),
       "the run's own process is not treated as a second run");

  PASS(!rejects(line(600, exe), exe),
       "the windowed app is not mistaken for a run");

  PASS(!rejects(line(601, [@"/usr/bin/sudo -A -E " stringByAppendingString:
                           [exe stringByAppendingString:@" --rebuild /tmp/x.plist"]]), exe),
       "the sudo wrapper that launched this run is not a second run");

  PASS(rejects(line(602, [exe stringByAppendingString:@" --run-update /tmp/y.plist"]), exe),
       "another update run is detected");

  PASS(rejects(line(603, [exe stringByAppendingString:@" --rebuild /tmp/z.plist"]), exe),
       "another rebuild is detected");

  PASS(!rejects(line(604, @"clang Dialogs/AboutController.m -c -o foo.o"), exe),
       "an unrelated build process is not a run");

  PASS(!rejects(line(605, @"/bin/sh install-system-domain.sh build-repo libs-gui"), exe),
       "a manual build is not mistaken for a run (and is out of our reach)");

  PASS(!rejects(line(606, @"/usr/local/bin/othertool --rebuild /tmp/q"), exe),
       "another program's --rebuild is not mistaken for ours");

  // A path that merely ends the same way must not match, or an unrelated app
  // called SoftwareUpdate elsewhere would block every run.
  PASS(!rejects(line(607, @"/opt/other/SoftwareUpdate.app/SoftwareUpdate --rebuild /tmp/r"), exe),
       "a different executable with the same basename is not ours");

  // A real listing has many other lines around ours; make sure one of them
  // being unrelated does not stop the search.
  PASS(rejects([NSString stringWithFormat:
                 @"1 /sbin/init\n2 /usr/lib/system/fseventsd\n3 %@\n4 /usr/bin/sshd\n",
                 [exe stringByAppendingString:@" --rebuild /tmp/s.plist"]], exe),
       "a run is found among unrelated processes");

  PASS(rejects([NSString stringWithFormat:
                 @"609 %@\n1 /sbin/init\n",
                 [exe stringByAppendingString:@" --run-update /tmp/s.plist"]], exe),
       "a run on the first line is found too");

  /* --- malformed input --- */

  PASS(!rejects(@"", exe), "an empty listing rejects nothing");
  PASS(!rejects(@"garbage without a pid", exe), "a line with no pid is ignored");
  PASS(!rejects(@"   \n  \n", exe), "whitespace is ignored");
  PASS(!rejects(nil, exe), "a nil listing rejects nothing");

  /* --- 2. the real process list, before and after a real decoy appears --- */

  {
    NSString *reason = nil;
    PASS([SWRunGuard acquireRunLockWithReason:&reason],
         "with nothing else running, the guard admits the run");
    PASS(reason == nil, "and reports no reason for saying so");
  }

  {
    NSTask *decoy = [[NSTask alloc] init];
    [decoy setLaunchPath:gSelfExecutable];
    [decoy setArguments:@[@"--rebuild", @"/tmp/SoftwareUpdate-run-decoy.plist"]];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"1" forKey:@"SW_TEST_DECOY"];
    [decoy setEnvironment:env];
    NSPipe *sink = [NSPipe pipe];
    [decoy setStandardOutput:sink];
    [decoy setStandardError:sink];

    @try {
      [decoy launch];
    } @catch (NSException *exception) {
      PASS(NO, "the decoy process could be started");
      [arp release];
      return 0;
    }
    PASS(YES, "the decoy process could be started");

    // Give ps a moment to see it. The guard is a one-shot check, so this is
    // the same as any other polling loop in a test.
    [NSThread sleepForTimeInterval:1.0];

    NSString *reason = nil;
    BOOL acquired = [SWRunGuard acquireRunLockWithReason:&reason];
    PASS(!acquired,
         "with a real competing run in the process table, the guard refuses");
    PASS([reason rangeOfString:@"already in progress"].location != NSNotFound,
         "the refusal says another run is in progress");
    NSString *decoyPID = [NSString stringWithFormat:@"%d", (int)[decoy processIdentifier]];
    PASS([reason rangeOfString:decoyPID].location != NSNotFound,
         "the refusal names the other run's process id");

    // And it must be the specific decoy, not some unrelated match: the
    // classification requires a line to start with our own executable, and the
    // message is for a person, so it names a pid rather than quoting a path.
    PASS([reason rangeOfString:gSelfExecutable].location == NSNotFound,
         "the refusal names a process, not the path back at the user");

    [decoy terminate];
    [decoy waitUntilExit];
    [[NSFileManager defaultManager] removeItemAtPath:decoyPIDPath() error:NULL];

    // The property the whole design rests on: a dead run must stop existing.
    [NSThread sleepForTimeInterval:0.5];
    NSString *afterReason = nil;
    PASS([SWRunGuard acquireRunLockWithReason:&afterReason],
         "once the other run is gone the guard admits the next one immediately");
  }

  [arp release];
  return 0;
}
