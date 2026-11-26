/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "GSCrashReporter.h"
#import "GSCrashConstants.h"
#import "GSCrashReport.h"
#import "GSCrashPlatform.h"
#import <sys/resource.h>
#import <signal.h>

/* ---- helpers ---- */

static NSString *g_ctlName = @"gs-crashctl";

static void usage(void)
{
  fprintf(stderr,
    "usage: %s <command> [args]\n"
    "  status                 show crash reporter status\n"
    "  enable                 configure core dumps and start the daemon\n"
    "  disable                restore core config and stop the daemon\n"
    "  test                   trigger a self-identified TEST crash\n"
    "  list                   list recorded crash reports\n"
    "  show <crash-id>        print a report as text\n"
    "  analyze <crash-dir>    re-run the analyzer on a crash directory\n"
    "  open <crash-id>        print (and try to open) a crash directory\n",
    [g_ctlName UTF8String]);
}

/* Resolve an executable name to a full path using $PATH. */
static NSString *findExecutable(NSString *name)
{
  NSString *pathEnv = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
  NSArray *dirs = [pathEnv componentsSeparatedByString:@":"];
  for (NSString *dir in dirs)
    {
      NSString *candidate = [dir stringByAppendingPathComponent:name];
      if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate])
        return candidate;
    }
  /* common extra locations */
  NSArray *extra = @[@"/System/Library/CrashReporter",
                     @"/System/bin", @"/usr/local/bin"];
  for (NSString *dir in extra)
    {
      NSString *candidate = [dir stringByAppendingPathComponent:name];
      if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate])
        return candidate;
    }
  return nil;
}

/* PID of a running gs-crashd, or 0 if not running. */
static pid_t daemonPID(void)
{
  NSString *base = GSCrashBaseDirectory();
  NSString *pidPath = [base stringByAppendingPathComponent:@"gs-crashd.pid"];
  NSString *pidStr = [NSString stringWithContentsOfFile:pidPath
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
  if (pidStr)
    {
      pid_t pid = (pid_t)[pidStr integerValue];
      if (pid > 0)
        return pid;
    }
  /* fall back to pgrep */
  NSTask *pgrep = [[NSTask alloc] init];
  [pgrep setLaunchPath:@"/bin/pgrep"];
  [pgrep setArguments:@[@"-x", @"gs-crashd"]];
  NSPipe *outPipe = [NSPipe pipe];
  [pgrep setStandardOutput:outPipe];
  @try { [pgrep launch]; [pgrep waitUntilExit]; }
  @catch (id e) { return 0; }
  NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
  NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (out.length > 0)
    return (pid_t)[out integerValue];
  return 0;
}

static BOOL fileExists(NSString *path)
{
  return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/* Send a signal to the daemon pid recorded in the pidfile. */
static BOOL stopDaemon(void)
{
  pid_t pid = daemonPID();
  if (pid == 0)
    return NO;
  if (kill(pid, SIGTERM) == 0)
    return YES;
  return NO;
}

/* Launch gs-crashd in the background if not already running. */
static BOOL startDaemon(void)
{
  if (daemonPID() != 0)
    return YES;
  NSString *exe = findExecutable(@"gs-crashd");
  if (!exe)
    {
      fprintf(stderr, "warning: gs-crashd not found in PATH; cannot start service\n");
      return NO;
    }
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:exe];
  [task setArguments:@[]];
  @try { [task launch]; }
  @catch (id e)
    {
      fprintf(stderr, "warning: failed to launch gs-crashd: %s\n",
              [[e description] UTF8String]);
      return NO;
    }
  return YES;
}

/* Find all crash directories (base/<App>/<stamp>-<pid>) newest last. */
static NSArray *allCrashDirectories(void)
{
  NSMutableArray *result = [NSMutableArray array];
  NSString *base = GSCrashBaseDirectory();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *appDirs = [fm contentsOfDirectoryAtPath:base error:NULL];
  for (NSString *app in appDirs)
    {
      NSString *appPath = [base stringByAppendingPathComponent:app];
      BOOL isDir = NO;
      if (![fm fileExistsAtPath:appPath isDirectory:&isDir] || !isDir)
        continue;
      NSArray *crashes = [fm contentsOfDirectoryAtPath:appPath error:NULL];
      for (NSString *crash in crashes)
        {
          NSString *crashPath = [appPath stringByAppendingPathComponent:crash];
          BOOL cIsDir = NO;
          if ([fm fileExistsAtPath:crashPath isDirectory:&cIsDir] && cIsDir)
            [result addObject:crashPath];
        }
    }
  [result sortUsingComparator:^NSComparisonResult(id a, id b) {
    NSDate *da = [[fm attributesOfItemAtPath:a error:NULL] fileModificationDate];
    NSDate *db = [[fm attributesOfItemAtPath:b error:NULL] fileModificationDate];
    return [da compare:db];
  }];
  return result;
}

/* Resolve a crash-id (full path or <App>/<stamp>-<pid>) to a full path. */
static NSString *resolveCrashID(NSString *crashID)
{
  if ([crashID isAbsolutePath] && fileExists(crashID))
    return crashID;
  NSString *candidate = [GSCrashBaseDirectory() stringByAppendingPathComponent:crashID];
  if (fileExists(candidate))
    return candidate;
  return nil;
}

/* ---- subcommands ---- */

static int cmd_status(void)
{
  id<GSCrashPlatform> platform = GSCrashPlatformForCurrentOS();
  NSString *service = (daemonPID() != 0) ? @"running" : @"not running";
  NSString *core = [platform isCoreDumpingEnabled] ? @"enabled" : @"disabled";
  NSString *coreLoc = [platform coreDumpLocation];
  if (!coreLoc)
    coreLoc = @"unknown";
  NSString *platformName = [platform platformName];
  if (!platformName)
    platformName = @"unknown";
  NSString *collector = [platform existingCrashCollector];
  if (!collector)
    collector = @"none";

  BOOL symbolication = fileExists(@"/bin/gdb") || fileExists(@"/usr/bin/gdb")
                     || fileExists(@"/bin/lldb") || fileExists(@"/usr/bin/lldb");
  NSString *symbolStr = symbolication ? @"available" : @"unavailable";

  printf("GNUstep CrashReporter\n");
  printf("  Service:             %s\n", [service UTF8String]);
  printf("  Core dumps:          %s\n", [core UTF8String]);
  printf("  Core location:       %s\n", [coreLoc UTF8String]);
  printf("  Platform:            %s\n", [platformName UTF8String]);
  printf("  Crash collector:     %s\n", [collector UTF8String]);
  printf("  Symbolication:       %s\n", [symbolStr UTF8String]);
  printf("  Debug symbols:       partial\n");
  return 0;
}

static int cmd_enable(void)
{
  id<GSCrashPlatform> platform = GSCrashPlatformForCurrentOS();
  NSError *err = nil;
  if ([platform configureCoreDumpsToDirectory:GSCrashBaseDirectory() error:&err])
    {
      printf("Core dumps configured to: %s\n",
             [[GSCrashBaseDirectory() stringByAppendingPathComponent:@"inbox"] UTF8String]);
    }
  else
    {
      printf("Core dump configuration degraded: %s\n",
             err ? [[err localizedDescription] UTF8String] : "unknown reason");
    }
  if (startDaemon())
    printf("Crash service started.\n");
  else
    printf("Crash service could not be started.\n");
  return 0;
}

static int cmd_disable(void)
{
  id<GSCrashPlatform> platform = GSCrashPlatformForCurrentOS();
  NSError *err = nil;
  if ([platform restoreCoreConfiguration:&err])
    printf("Core configuration restored.\n");
  else
    printf("Core configuration restore failed: %s\n",
           err ? [[err localizedDescription] UTF8String] : "unknown reason");
  if (stopDaemon())
    printf("Crash service stopped.\n");
  else
    printf("Crash service was not running.\n");
  return 0;
}

static int cmd_test(void)
{
  if (!startDaemon())
    fprintf(stderr, "warning: gs-crashd not running; core may not be collected\n");

  NSString *inbox = [GSCrashBaseDirectory() stringByAppendingPathComponent:@"inbox"];
  [[NSFileManager defaultManager] createDirectoryAtPath:inbox
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];

  NSString *testExe = findExecutable(@"gs-crash-test");
  if (!testExe)
    {
      fprintf(stderr, "error: gs-crash-test binary not found in PATH\n");
      return 1;
    }

  NSDate *before = [NSDate date];
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:testExe];
  [task setCurrentDirectoryPath:inbox];
  /* The test helper links libGSCrashReporter; pass the library path along. */
  NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
  NSString *exeDir = [testExe stringByDeletingLastPathComponent];
  NSString *repoDir = [[exeDir stringByDeletingLastPathComponent]
                        stringByDeletingLastPathComponent];
  NSString *libDir = [[repoDir stringByAppendingPathComponent:@"Library/obj"]
                       stringByStandardizingPath];
  NSString *existing = env[@"LD_LIBRARY_PATH"];
  env[@"LD_LIBRARY_PATH"] = existing
    ? [existing stringByAppendingFormat:@":%@", libDir]
    : libDir;
  [task setEnvironment:env];
  @try { [task launch]; [task waitUntilExit]; }
  @catch (id e)
    {
      fprintf(stderr, "error running gs-crash-test: %s\n", [[e description] UTF8String]);
      return 1;
    }

  /* give the daemon a few seconds to collect the core */
  [NSThread sleepForTimeInterval:4.0];

  NSArray *dirs = allCrashDirectories();
  NSString *newest = nil;
  for (NSString *d in [dirs reverseObjectEnumerator])
    {
      NSDate *mod = [[[NSFileManager defaultManager] attributesOfItemAtPath:d error:NULL]
                      fileModificationDate];
      if ([mod compare:before] == NSOrderedDescending)
        {
          newest = d;
          break;
        }
    }

  printf("TEST crash triggered (self-identified, not a real crash).\n");
  if (newest)
    {
      printf("Crash report: %s\n", [newest UTF8String]);
      NSString *core = [newest stringByAppendingPathComponent:@"core"];
      printf("Core present: %s\n", fileExists(core) ? "yes" : "no (marker-based)");
    }
  else
    {
      printf("No crash report generated yet; a marker-based crash may still be "
             "recorded by gs-crashd.\n");
    }
  return 0;
}

static int cmd_list(void)
{
  NSArray *dirs = allCrashDirectories();
  if (dirs.count == 0)
    {
      printf("No crash reports recorded.\n");
      return 0;
    }
  printf("%-20s  %-22s  %-8s  %s\n", "APP", "TIMESTAMP", "PID", "SIGNAL/CLASS");
  for (NSString *d in dirs)
    {
      GSCrashReport *rep = [GSCrashReport reportFromDirectory:d];
      NSString *app = rep.applicationName ? rep.applicationName : @"?";
      NSString *ts = rep.timestamp ? [rep.timestamp description] : @"?";
      NSString *pid = [NSString stringWithFormat:@"%d", (int)rep.pid];
      NSString *sig = rep.signal ? rep.signal : @"?";
      if (rep.classification)
        sig = [sig stringByAppendingFormat:@" (%@)", rep.classification];
      printf("%-20s  %-22s  %-8s  %s\n",
             [app UTF8String], [ts UTF8String], [pid UTF8String], [sig UTF8String]);
    }
  return 0;
}

static int cmd_show(NSString *crashID)
{
  NSString *path = resolveCrashID(crashID);
  if (!path)
    {
      fprintf(stderr, "error: crash '%s' not found\n", [crashID UTF8String]);
      return 1;
    }
  GSCrashReport *rep = [GSCrashReport reportFromDirectory:path];
  if (rep)
    {
      printf("%s\n", [[rep textReport] UTF8String]);
    }
  else
    {
      NSString *txt = [path stringByAppendingPathComponent:@"report.txt"];
      if (fileExists(txt))
        {
          NSString *content = [NSString stringWithContentsOfFile:txt
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
          printf("%s\n", [content UTF8String]);
        }
      else
        {
          fprintf(stderr, "error: no report found in %s\n", [path UTF8String]);
          return 1;
        }
    }
  return 0;
}

static int cmd_analyze(NSString *crashDir)
{
  NSString *path = resolveCrashID(crashDir);
  if (!path)
    {
      fprintf(stderr, "error: crash directory '%s' not found\n", [crashDir UTF8String]);
      return 1;
    }
  NSString *analyzer = findExecutable(@"gs-crash-analyzer");
  if (!analyzer)
    {
      fprintf(stderr, "error: gs-crash-analyzer not found in PATH\n");
      return 1;
    }
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:analyzer];
  [task setArguments:@[path]];
  @try { [task launch]; [task waitUntilExit]; }
  @catch (id e)
    {
      fprintf(stderr, "error running analyzer: %s\n", [[e description] UTF8String]);
      return 1;
    }
  printf("Analyzer result in: %s\n", [path UTF8String]);
  return 0;
}

static int cmd_open(NSString *crashID)
{
  NSString *path = resolveCrashID(crashID);
  if (!path)
    {
      fprintf(stderr, "error: crash '%s' not found\n", [crashID UTF8String]);
      return 1;
    }
  printf("%s\n", [path UTF8String]);
  NSString *opener = findExecutable(@"xdg-open");
  if (!opener)
    opener = findExecutable(@"gio");
  if (opener)
    {
      NSTask *task = [[NSTask alloc] init];
      [task setLaunchPath:opener];
      [task setArguments:@[path]];
      @try { [task launch]; }
      @catch (id e) { /* ignore */ }
    }
  return 0;
}

int main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc < 2)
        {
          usage();
          return 1;
        }
      NSString *cmd = [NSString stringWithUTF8String:argv[1]];
      if ([cmd isEqualToString:@"status"])
        return cmd_status();
      if ([cmd isEqualToString:@"enable"])
        return cmd_enable();
      if ([cmd isEqualToString:@"disable"])
        return cmd_disable();
      if ([cmd isEqualToString:@"test"])
        return cmd_test();
      if ([cmd isEqualToString:@"list"])
        return cmd_list();
      if ([cmd isEqualToString:@"show"])
        {
          if (argc < 3) { usage(); return 1; }
          return cmd_show([NSString stringWithUTF8String:argv[2]]);
        }
      if ([cmd isEqualToString:@"analyze"])
        {
          if (argc < 3) { usage(); return 1; }
          return cmd_analyze([NSString stringWithUTF8String:argv[2]]);
        }
      if ([cmd isEqualToString:@"open"])
        {
          if (argc < 3) { usage(); return 1; }
          return cmd_open([NSString stringWithUTF8String:argv[2]]);
        }
      usage();
      return 1;
    }
}
