/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CrashReporterController.h"
#import <AppKit/AppKit.h>
#import <GSCrashReport.h>
#import <GSCrashConstants.h>
#import <GSCrashPlatform.h>

@class GSCrashDetailsWindowController;

@interface GSCrashDetailsWindowController : NSWindowController
{
  GSCrashReport *_report;
}
- (instancetype)initWithReport:(GSCrashReport *)report;
@end

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static NSString *
gscr_path_for_tool (NSString *tool)
{
  NSArray *searchPaths = @[
    [[[NSProcessInfo processInfo] environment][@"PATH"]
      componentsSeparatedByString:@":"],
    @[@"/System/Library/CoreServices",
      @"/System/bin", @"/usr/local/bin", @"/usr/bin"]
  ];
  NSMutableArray *dirs = [NSMutableArray array];
  for (NSArray *a in searchPaths)
    for (NSString *d in a)
      if ([d length] > 0)
        [dirs addObject:d];
  for (NSString *dir in dirs)
    {
      NSString *p = [dir stringByAppendingPathComponent:tool];
      if ([[NSFileManager defaultManager] isExecutableFileAtPath:p])
        return p;
    }
  return nil;
}

static void
gscr_launch_tool (NSString *tool, NSArray *args)
{
  NSString *path = gscr_path_for_tool (tool);
  if (path == nil)
    return;
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  if (args != nil)
    [task setArguments:args];
  @try
    {
      [task launch];
    }
  @catch (id ex)
    {
      /* best-effort; ignore launch failures */
    }
}

static BOOL
gscr_tool_available (NSString *tool)
{
  return gscr_path_for_tool (tool) != nil;
}

static NSString *
gscr_fmt_date (NSDate *date)
{
  if (date == nil)
    return @"unknown";
  NSDateFormatter *f = [[NSDateFormatter alloc] init];
  [f setDateFormat:@"d MMMM yyyy, HH:mm:ss"];
  return [f stringFromDate:date];
}

/* ------------------------------------------------------------------ */
/* Crash report window (SPEC 19, 21, 22)                               */
/* ------------------------------------------------------------------ */

@interface GSCrashReportWindowController : NSWindowController
{
  GSCrashReport *_report;
  NSAlert *_alert;
  GSCrashDetailsWindowController *_detailsController;
}
- (instancetype)initWithReport:(GSCrashReport *)report;
@end

@implementation GSCrashReportWindowController

- (instancetype)initWithReport:(GSCrashReport *)report
{
  _report = report;

  NSAlert *alert = [[NSAlert alloc] init];
  /* Standard alert icon + HIG layout: icon left, message, body, buttons. */
  [alert setAlertStyle:NSCriticalAlertStyle];

  NSString *appName = _report.applicationName ?: @"Application";
  [alert setMessageText:[NSString stringWithFormat:@"%@ quit unexpectedly.",
                            appName]];

  NSMutableString *info = [NSMutableString string];
  [info appendFormat:@"The application terminated because of a %@ (%@).",
                  (_report.classification ?: @"crash"),
                  _report.signal ?: @"unknown signal"];
  [info appendFormat:@"\n\nCrash time: %@", gscr_fmt_date (_report.timestamp)];
  if (_report.diagnosis != nil && [_report.diagnosis length] > 0)
    [info appendFormat:@"\n\nProbable cause: %@", _report.diagnosis];
  if (_report.coreAvailable == NO)
    {
      NSString *reason = _report.coreUnavailableReason
        ?: @"the operating system did not provide a core dump.";
      [info appendFormat:@"\n\nA crash was detected, but the core dump is "
                          @"unavailable because %@", reason];
    }
  [info appendFormat:@"\n\nA crash dump and diagnostic information were saved."];
  [info appendFormat:@"\n\nLocation: %@",
                  _report.crashDirectory ?: @"unknown location"];
  [alert setInformativeText:info];

  NSButton *details = [alert addButtonWithTitle:@"Show Details"];
  [details setTarget:self];
  [details setAction:@selector (showDetails:)];

  BOOL folderOK = gscr_tool_available (@"xdg-open")
                  || gscr_tool_available (@"gio");
  NSButton *openFolder = [alert addButtonWithTitle:@"Open Folder"];
  [openFolder setTarget:self];
  [openFolder setAction:@selector (openFolder:)];
  [openFolder setEnabled:folderOK];

  NSButton *copyPath = [alert addButtonWithTitle:@"Copy Path"];
  [copyPath setTarget:self];
  [copyPath setAction:@selector (copyPath:)];

  NSButton *close = [alert addButtonWithTitle:@"Close"];
  [close setKeyEquivalent:@"\r"];
  [close setTarget:self];
  [close setAction:@selector (closeWindow:)];

  _alert = alert;
  self = [super initWithWindow:[alert window]];
  if (self == nil)
    return nil;
  return self;
}

- (void)showDetails:(id)sender
{
  [self showDetailsWindow];
}

- (void)showDetailsWindow
{
  /* Lazily-built details panel (SPEC 20) */
  if (_detailsController == nil)
    _detailsController =
      [[GSCrashDetailsWindowController alloc] initWithReport:_report];
  [_detailsController showWindow:self];
  [[_detailsController window] makeKeyAndOrderFront:self];
}

- (void)openFolder:(id)sender
{
  NSString *dir = _report.crashDirectory;
  if (dir == nil)
    return;
  NSString *tool = gscr_tool_available (@"xdg-open") ? @"xdg-open"
                                                     : @"gio";
  NSArray *args = gscr_tool_available (@"xdg-open")
    ? @[dir] : @[@"open", dir];
  gscr_launch_tool (tool, args);
}

- (void)copyPath:(id)sender
{
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb declareTypes:@[NSStringPboardType] owner:nil];
  [pb setString:(_report.crashDirectory ?: @"") forType:NSStringPboardType];
}

- (void)closeWindow:(id)sender
{
  [[self window] orderOut:self];
}

@end

/* ------------------------------------------------------------------ */
/* Details panel (SPEC 20)                                             */
/* ------------------------------------------------------------------ */

@implementation GSCrashDetailsWindowController

- (instancetype)initWithReport:(GSCrashReport *)report
{
  _report = report;
  NSRect r = NSMakeRect (0, 0, 640, 520);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                              styleMask:(NSTitledWindowMask
                                                         | NSClosableWindowMask
                                                         | NSResizableWindowMask
                                                         | NSMiniaturizableWindowMask)
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
  [win setTitle:[NSString stringWithFormat:@"Crash Details - %@",
                  (_report.applicationName ?: @"Application")]];
  self = [super initWithWindow:win];
  if (self == nil)
    return nil;

  NSScrollView *scroll = [[NSScrollView alloc]
    initWithFrame:[[win contentView] bounds]];
  [scroll setHasVerticalScroller:YES];
  [scroll setHasHorizontalScroller:YES];
  [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  NSTextView *tv = [[NSTextView alloc]
    initWithFrame:[[win contentView] bounds]];
  [tv setEditable:NO];
  [tv setSelectable:YES];
  [tv setFont:[NSFont userFixedPitchFontOfSize:10]];
  [tv setString:[self detailString]];
  [scroll setDocumentView:tv];
  [[win contentView] addSubview:scroll];
  return self;
}

- (NSString *)detailString
{
  GSCrashReport *r = _report;
  NSMutableString *s = [NSMutableString string];

  void (^sec)(NSString *) = ^(NSString *name){
    [s appendFormat:@"\n%@\n%@\n", name,
          [@"" stringByPaddingToLength:[name length]
                            withString:@"-"
                       startingAtIndex:0]];
  };

  sec (@"Application");
  [s appendFormat:@"  Name:    %@\n", r.applicationName ?: @"unknown"];
  [s appendFormat:@"  Version: %@\n", r.applicationVersion ?: @"unknown"];
  [s appendFormat:@"  PID:     %d\n", (int)r.pid];
  [s appendFormat:@"  Exec:    %@\n", r.executablePath ?: @"unknown"];
  [s appendFormat:@"  UID:     %d\n", (int)r.uid];

  sec (@"System");
  [s appendFormat:@"  Host:      %@\n", r.hostname ?: @"unknown"];
  [s appendFormat:@"  OS:        %@ %@\n", r.osName ?: @"unknown",
                  r.osVersion ?: @""];
  [s appendFormat:@"  Arch:      %@\n", r.architecture ?: @"unknown"];
  [s appendFormat:@"  GNUstep:   base %@ / gui %@\n",
                  r.gnustepBaseVersion ?: @"unknown",
                  r.gnustepGuiVersion ?: @"unknown"];
  [s appendFormat:@"  Build ID:  %@\n", r.buildID ?: @"unknown"];
  [s appendFormat:@"  Time:      %@\n", gscr_fmt_date (r.timestamp)];

  sec (@"Crash");
  [s appendFormat:@"  Signal:       %@\n", r.signal ?: @"unknown"];
  [s appendFormat:@"  Fault:        %@\n", r.faultAddress ?: @"unknown"];
  [s appendFormat:@"  Thread:       %ld\n", (long)r.crashingThread];
  [s appendFormat:@"  Instruction:  %@\n", r.instructionPointer ?: @"unknown"];
  [s appendFormat:@"  Stack:        %@\n", r.stackPointer ?: @"unknown"];
  [s appendFormat:@"  Core:         %@\n",
                  r.coreAvailable ? @"available" : @"UNAVAILABLE"];
  if (r.coreAvailable == NO && r.coreUnavailableReason)
    [s appendFormat:@"    reason: %@\n", r.coreUnavailableReason];
  [s appendFormat:@"  Symbols:      %@\n",
                  r.symbolsAvailable ? @"available" : @"unavailable"];

  sec (@"Exception");
  [s appendFormat:@"  Name:   %@\n", r.exceptionName ?: @"(none)"];
  [s appendFormat:@"  Reason: %@\n", r.exceptionReason ?: @"(none)"];

  sec (@"Crashing Thread");
  [s appendFormat:@"  Thread %ld:\n", (long)r.crashingThread];
  for (NSString *line in r.backtrace)
    [s appendFormat:@"    %@\n", line];

  sec (@"Other Threads");
  for (NSDictionary *t in r.threads)
    {
      if ([t[@"crashed"] boolValue])
        continue;
      [s appendFormat:@"  Thread %@ (%@):\n", t[@"id"], t[@"name"] ?: @""];
      NSArray *frames = t[@"frames"];
      for (NSString *fl in frames)
        [s appendFormat:@"    %@\n", fl];
    }
  if ([r.threads count] == 0)
    [s appendString:@"  (no thread data)\n"];

  sec (@"Loaded Libraries");
  for (NSString *lib in r.loadedLibraries)
    [s appendFormat:@"  %@\n", lib];
  if ([r.loadedLibraries count] == 0)
    [s appendString:@"  (none recorded)\n"];

  sec (@"Crash Files");
  [s appendFormat:@"  Directory: %@\n", r.crashDirectory ?: @"unknown"];
  [s appendFormat:@"  Core:      %@\n", r.coreDumpPath ?: @"(none)"];
  [s appendFormat:@"  Report:    %@\n",
                  [r.crashDirectory
                    stringByAppendingPathComponent:GSCrashReportJSON]];

  if (r.diagnosis)
    {
      sec (@"Diagnosis");
      [s appendFormat:@"  %@ (%@)\n", r.diagnosis,
                      r.diagnosisConfidence ?: @"Unknown"];
    }

  return s;
}

@end

/* ------------------------------------------------------------------ */
/* Main controller / app delegate                                      */
/* ------------------------------------------------------------------ */

@implementation CrashReporterController

{
  NSWindow *_mainWindow;
  NSTableView *_tableView;
  NSMutableArray *_reports;
  NSMutableArray *_crashWindows;
  BOOL _configAlertShown;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  _reports = [[NSMutableArray alloc] init];
  _crashWindows = [[NSMutableArray alloc] init];

  [self ensureDaemonRunning];
  [self buildMainWindow];
  [self refreshReports];
  [self checkConfiguration];

  [[NSDistributedNotificationCenter defaultCenter]
          addObserver:self
             selector:@selector (crashDetected:)
                 name:GSCrashNotificationName
               object:nil];
}

- (void)dealloc
{
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

/* SPEC 4: partial configuration alert */
- (void)checkConfiguration
{
  id<GSCrashPlatform> platform = GSCrashPlatformForCurrentOS ();
  if (platform == nil)
    return;

  BOOL coreOK = [platform isCoreDumpingEnabled];
  NSString *collector = [platform existingCrashCollector];
  BOOL unsupported = (collector != nil
                      && ![collector isEqualToString:@"none"]
                      && ![collector isEqualToString:@"kernel"]);

  if (coreOK && !unsupported)
    return;

  /* Show at most once; never block the run loop (a nested modal session in
     -applicationDidFinishLaunching: is what made the Eau alert re-present). */
  if (_configAlertShown)
    return;
  _configAlertShown = YES;

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setAlertStyle:NSInformationalAlertStyle];
  [alert setMessageText:@"Crash collection partially configured"];
  [alert setInformativeText:
      @"Crash dump collection is partially configured. Core dumps may not "
      @"be available because the operating system or security policy prevents "
      @"CrashReporter from configuring them."];
  [alert addButtonWithTitle:@"Enable"];
  [alert addButtonWithTitle:@"Later"];

  if (_mainWindow != nil)
    {
      [alert beginSheetModalForWindow:_mainWindow
                    modalDelegate:self
                   didEndSelector:@selector
                       (configAlertDidEnd:returnCode:contextInfo:)
                      contextInfo:NULL];
    }
  else
    {
      NSModalResponse resp = [alert runModal];
      if (resp == NSAlertFirstButtonReturn)
        gscr_launch_tool (@"gs-crashctl", @[@"enable"]);
    }
}

- (void)configAlertDidEnd:(NSAlert *)alert
               returnCode:(NSInteger)returnCode
              contextInfo:(void *)contextInfo
{
  if (returnCode == NSAlertFirstButtonReturn)
    gscr_launch_tool (@"gs-crashctl", @[@"enable"]);
}

/* SPEC 4: ensure gs-crashd is started */
- (void)ensureDaemonRunning
{
  gscr_launch_tool (@"gs-crashd", nil);
}

/* Main window listing recent crashes */
- (void)buildMainWindow
{
  NSRect r = NSMakeRect (100, 300, 560, 380);
  _mainWindow = [[NSWindow alloc]
    initWithContentRect:r
              styleMask:(NSTitledWindowMask | NSClosableWindowMask
                         | NSMiniaturizableWindowMask | NSResizableWindowMask)
                backing:NSBackingStoreBuffered
                  defer:YES];
  [_mainWindow setTitle:@"CrashReporter"];
  [_mainWindow setReleasedWhenClosed:NO];

  NSView *cv = [_mainWindow contentView];
  CGFloat w = [cv bounds].size.width;

  NSTextField *hdr = [[NSTextField alloc]
    initWithFrame:NSMakeRect (20, [cv bounds].size.height - 36, w - 40, 20)];
  [hdr setStringValue:@"Recent crashes"];
  [hdr setBezeled:NO];
  [hdr setDrawsBackground:NO];
  [hdr setEditable:NO];
  [hdr setSelectable:NO];
  [hdr setFont:[NSFont boldSystemFontOfSize:13]];
  [cv addSubview:hdr];

  NSScrollView *scroll = [[NSScrollView alloc]
    initWithFrame:NSMakeRect (20, 50, w - 40,
                              [cv bounds].size.height - 90)];
  [scroll setHasVerticalScroller:YES];
  [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

  _tableView = [[NSTableView alloc] initWithFrame:[scroll bounds]];
  NSTableColumn *c1 =
    [[NSTableColumn alloc] initWithIdentifier:@"app"];
  [c1 setHeaderCell:[[NSTableHeaderCell alloc]
                      initTextCell:@"Application"]];
  [c1 setWidth:180];
  [_tableView addTableColumn:c1];

  NSTableColumn *c2 =
    [[NSTableColumn alloc] initWithIdentifier:@"date"];
  [c2 setHeaderCell:[[NSTableHeaderCell alloc] initTextCell:@"Date"]];
  [c2 setWidth:200];
  [_tableView addTableColumn:c2];

  NSTableColumn *c3 =
    [[NSTableColumn alloc] initWithIdentifier:@"signal"];
  [c3 setHeaderCell:[[NSTableHeaderCell alloc] initTextCell:@"Signal"]];
  [c3 setWidth:120];
  [_tableView addTableColumn:c3];

  [_tableView setDataSource:self];
  [_tableView setDelegate:self];
  [_tableView setDoubleAction:@selector (doubleClicked:)];
  [scroll setDocumentView:_tableView];
  [cv addSubview:scroll];

  [_mainWindow makeKeyAndOrderFront:self];
}

- (void)refreshReports
{
  [_reports removeAllObjects];
  NSString *base = GSCrashBaseDirectory ();
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDirectoryEnumerator *apps =
    [fm enumeratorAtPath:base];
  for (NSString *app in apps)
    {
      NSString *appPath = [base stringByAppendingPathComponent:app];
      BOOL isDir = NO;
      [fm fileExistsAtPath:appPath isDirectory:&isDir];
      if (!isDir)
        continue;
      NSDirectoryEnumerator *crashes =
        [fm enumeratorAtPath:appPath];
      for (NSString *cr in crashes)
        {
          NSString *dir = [appPath stringByAppendingPathComponent:cr];
          BOOL d2 = NO;
          [fm fileExistsAtPath:dir isDirectory:&d2];
          if (!d2)
            continue;
          GSCrashReport *rep = [GSCrashReport reportFromDirectory:dir];
          if (rep != nil)
            [_reports addObject:rep];
        }
    }
  [_reports sortUsingComparator:^NSComparisonResult (id a, id b) {
    NSDate *da = [(GSCrashReport *)a timestamp];
    NSDate *db = [(GSCrashReport *)b timestamp];
    return [db compare:da];
  }];
  [_tableView reloadData];
}

/* NSTableViewDataSource */
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
  return [_reports count];
}

- (id)tableView:(NSTableView *)tv
      objectValueForTableColumn:(NSTableColumn *)col
                            row:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)[_reports count])
    return nil;
  GSCrashReport *r = _reports[row];
  NSString *id = [col identifier];
  if ([id isEqualToString:@"app"])
    return r.applicationName ?: @"(unknown)";
  if ([id isEqualToString:@"date"])
    return gscr_fmt_date (r.timestamp);
  if ([id isEqualToString:@"signal"])
    return r.signal ?: @"?";
  return nil;
}

- (void)doubleClicked:(id)sender
{
  NSInteger row = [_tableView clickedRow];
  if (row < 0 || row >= (NSInteger)[_reports count])
    return;
  GSCrashReport *r = _reports[row];
  /* Open the "what to do with this crash report" dialog (the same NSAlert-style
     panel shown for a fresh crash); its "Show Details" button reveals the full
     report. */
  GSCrashReportWindowController *wc =
    [[GSCrashReportWindowController alloc] initWithReport:r];
  [wc showWindow:self];
  [[wc window] makeKeyAndOrderFront:self];
  [_crashWindows addObject:wc];
}

/* SPEC 4: handle incoming crash notifications */
- (void)crashDetected:(NSNotification *)note
{
  NSDictionary *ui = [note userInfo];
  NSString *dir = [ui objectForKey:GSCrashNotificationCrashDirKey];
  if (dir == nil)
    return;
  GSCrashReport *rep = [GSCrashReport reportFromDirectory:dir];
  if (rep == nil)
    return;
  [_reports insertObject:rep atIndex:0];
  [_tableView reloadData];
  GSCrashReportWindowController *wc =
    [[GSCrashReportWindowController alloc] initWithReport:rep];
  [wc showWindow:self];
  [[wc window] makeKeyAndOrderFront:self];
  [_crashWindows addObject:wc];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return NO;
}

@end
