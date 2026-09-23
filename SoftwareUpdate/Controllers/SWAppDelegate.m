/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SWAppDelegate.h"
#import "SWCheckingWindowController.h"
#import "SWMainWindowController.h"
#import "SWProgressWindowController.h"
#import "SWStashAlertController.h"
#import "SWCompletionWindowController.h"
#import "SWRepositoryList.h"
#import "SWUpdateChecker.h"
#import "SWRepositoryUpdater.h"
#import <PackageManager/ODLogWindowController.h>
#import <PackageManager/GWSudoHelper.h>

// /Developer is the gershwin-developer clone; never hard-code anything about
// its contents beyond these well-known, spec-defined paths.
static NSString *const kGershwinDeveloperPath = @"/Developer";

@interface SWAppDelegate () <SWCheckingWindowControllerDelegate, SWMainWindowControllerDelegate,
                              SWProgressWindowControllerDelegate, SWCompletionWindowControllerDelegate>
{
  ODLogWindowController *_logController;
  NSMenuItem *_showLogMenuItem;
  SWCheckingWindowController *_checkingWindow;
  SWMainWindowController *_mainWindow;
  SWProgressWindowController *_progressWindow;
  SWCompletionWindowController *_completionWindow;
  SWUpdateChecker *_checker;
  NSArray<SWRepository *> *_allCheckedRepositories; // every repository the last check reached
  BOOL _useDevBranch;
  BOOL _stopRequested;

  NSTask *_updateTask;
  NSFileHandle *_updateReadHandle;
  NSString *_updateArgsPath;
  NSArray<SWRepository *> *_updateRepositories; // as confirmed, in run order (developer first if present)
  NSString *_updateCurrentPhase;                // "developer" / "prereqs" / "repos"
  NSUInteger _updateUnitsTotal;
  NSUInteger _updateUnitsCompleted;
  NSMutableArray<SWCompletionResultRow *> *_updateResultRows;
  NSMutableArray<SWStashConflict *> *_updateStashConflicts;
  BOOL _updateWasStopped;
  BOOL _updateFatalOccurred;
  BOOL _updateFatalAlertShown;
}
@end

@implementation SWAppDelegate

#pragma mark - Menu

- (void)buildMainMenu
{
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
  NSString *appName = @"Software Update";

  NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:appName action:nil keyEquivalent:@""];
  [mainMenu addItem:appMenuItem];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
  [appMenu addItemWithTitle:@"About Software Update" action:@selector(showAbout:) keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Software Update" action:@selector(terminate:) keyEquivalent:@"q"];
  [appMenuItem setSubmenu:appMenu];

  NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
  [mainMenu addItem:fileMenuItem];
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [fileMenu addItemWithTitle:@"Check Now" action:@selector(checkNow:) keyEquivalent:@"r"];
  [fileMenuItem setSubmenu:fileMenu];

  NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
  [mainMenu addItem:windowMenuItem];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  _showLogMenuItem = (NSMenuItem *)[windowMenu addItemWithTitle:@"Show Log" action:@selector(toggleLog:) keyEquivalent:@"l"];
  [windowMenuItem setSubmenu:windowMenu];
  [NSApp setWindowsMenu:windowMenu];

  [NSApp setMainMenu:mainMenu];
}

- (void)showAbout:(id)sender
{
  [NSApp orderFrontStandardAboutPanel:sender];
}

- (void)toggleLog:(id)sender
{
  NSWindow *logWindow = [_logController window];
  if ([logWindow isVisible]) {
    [logWindow orderOut:nil];
    [_showLogMenuItem setTitle:@"Show Log"];
  } else {
    [logWindow makeKeyAndOrderFront:nil];
    [_showLogMenuItem setTitle:@"Hide Log"];
  }
}

#pragma mark - NSApplicationDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  _logController = [[ODLogWindowController alloc] initWithTitle:@"Software Update Log"];
  [_logController setLogFont:[NSFont systemFontOfSize:11]]; // no monospaced font, per spec
  // The log window itself only opens on request (per spec), so a run that
  // fails before the user thinks to check it - or after they close the app -
  // would otherwise leave no trace of what actually happened.
  [_logController setLogFilePath:@"/tmp/SoftwareUpdate.log"];

  [self buildMainMenu];

  _useDevBranch = [[NSUserDefaults standardUserDefaults] boolForKey:@"UseDevelopmentBranch"];

  [self checkNow:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return YES;
}

#pragma mark - Checking

- (void)checkNow:(id)sender
{
  NSString *csvPath = [kGershwinDeveloperPath stringByAppendingPathComponent:@"Library/Repositories.csv"];
  NSError *error = nil;
  NSArray<SWRepository *> *repositories = [SWRepositoryList repositoriesFromCSVAtPath:csvPath error:&error];
  if (!repositories) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Software Update can't read the repository list."];
    [alert setInformativeText:[error localizedDescription] ?: @""];
    [alert runModal];
    [NSApp terminate:nil];
    return;
  }

  if (!_checkingWindow) {
    _checkingWindow = [[SWCheckingWindowController alloc] init];
    [_checkingWindow setDelegate:self];
  }
  [[_mainWindow window] orderOut:nil];
  [[_checkingWindow window] makeKeyAndOrderFront:nil];

  _stopRequested = NO;
  __weak SWAppDelegate *weakSelf = self;
  SWGitLogLine logHandler = ^(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
      SWAppDelegate *strongSelf = weakSelf;
      [strongSelf->_logController appendLog:[line stringByAppendingString:@"\n"]];
    });
  };

  _checker = [[SWUpdateChecker alloc] initWithSourcesDirectory:
                [kGershwinDeveloperPath stringByAppendingPathComponent:@"Library/Sources"]
                                                    useDevBranch:_useDevBranch
                                                  gitToolFactory:nil
                                               buildStatusClient:nil
                                                      logHandler:logHandler];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    SWAppDelegate *strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf->_checker checkRepositories:repositories
                               stopRequested:^BOOL { return strongSelf->_stopRequested; }
                                    progress:^(SWRepository *repo, NSUInteger index, NSUInteger total) {
      dispatch_async(dispatch_get_main_queue(), ^{
        SWAppDelegate *innerSelf = weakSelf;
        [innerSelf->_checkingWindow setStatusRepositoryName:[repo name] index:index total:total];
      });
    }
                                  completion:^(NSArray<SWRepository *> *withUpdates, BOOL anyReachable) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf finishCheckWithAllRepositories:repositories
                                  repositoriesWithUpdates:withUpdates
                                             anyReachable:anyReachable];
      });
    }];
  });
}

- (void)finishCheckWithAllRepositories:(NSArray<SWRepository *> *)all
                repositoriesWithUpdates:(NSArray<SWRepository *> *)withUpdates
                           anyReachable:(BOOL)anyReachable
{
  [[_checkingWindow window] orderOut:nil];
  _allCheckedRepositories = all;
  [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"LastCheckDate"];

  // "Use Development branch" defaults to whatever gershwin-developer's own
  // checkout already is, not a remembered preference - if someone puts
  // gershwin-developer on dev by hand, this app should keep tracking dev
  // without them also having to flip this checkbox. The initial check pass
  // above already ran with the previous value; only redo it (same call the
  // checkbox's own toggle handler uses) when that guess turns out wrong, so
  // the common case where nothing changed costs nothing extra.
  SWRepository *developer = nil;
  for (SWRepository *repo in all) {
    if ([[repo name] isEqualToString:@"gershwin-developer"]) { developer = repo; break; }
  }
  BOOL developerOnDev = [[developer currentBranch] isEqualToString:@"dev"];
  if (developer && developerOnDev != _useDevBranch) {
    _useDevBranch = developerOnDev;
    [[NSUserDefaults standardUserDefaults] setBool:_useDevBranch forKey:@"UseDevelopmentBranch"];
    [_checker recomputeTargetBranchForRepositories:all useDevBranch:_useDevBranch];
    NSMutableArray *recomputed = [NSMutableArray array];
    for (SWRepository *repo in all) {
      if ([repo hasUpdate]) [recomputed addObject:repo];
    }
    withUpdates = [recomputed copy];
  }

  if (!anyReachable) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Software Update can't reach GitHub."];
    [alert setInformativeText:@"Check your network connection and try again."];
    [alert runModal];
    [NSApp terminate:nil];
    return;
  }

  if ([withUpdates count] == 0) {
    // Being up to date is not a problem, so it should not wear the same
    // caution icon as a real error - NSAlert defaults to that icon unless
    // given one explicitly.
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setIcon:[NSImage imageNamed:@"SoftwareUpdate"]];
    [alert setMessageText:@"Your software is up to date."];
    [alert runModal];
    [NSApp terminate:nil];
    return;
  }

  [self showMainWindowWithUpdates:withUpdates all:all];
}

- (void)showMainWindowWithUpdates:(NSArray<SWRepository *> *)withUpdates all:(NSArray<SWRepository *> *)all
{
  if (!_mainWindow) {
    _mainWindow = [[SWMainWindowController alloc] init];
    [_mainWindow setDelegate:self];
  }
  NSUInteger upToDateCount = [all count] - [withUpdates count];
  [_mainWindow setRepositories:withUpdates upToDateCount:upToDateCount useDevelopmentBranch:_useDevBranch];
  [[_mainWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - SWCheckingWindowControllerDelegate

- (void)checkingWindowControllerDidClickStop:(SWCheckingWindowController *)controller
{
  _stopRequested = YES;
}

#pragma mark - SWMainWindowControllerDelegate

- (void)mainWindowController:(SWMainWindowController *)controller
       useDevelopmentBranchDidChange:(BOOL)useDevBranch
{
  _useDevBranch = useDevBranch;
  [[NSUserDefaults standardUserDefaults] setBool:useDevBranch forKey:@"UseDevelopmentBranch"];

  __weak SWAppDelegate *weakSelf = self;
  NSArray *all = _allCheckedRepositories;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    SWAppDelegate *strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf->_checker recomputeTargetBranchForRepositories:all useDevBranch:useDevBranch];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSMutableArray *withUpdates = [NSMutableArray array];
      for (SWRepository *repo in all) {
        if ([repo hasUpdate]) [withUpdates addObject:repo];
      }
      [weakSelf showMainWindowWithUpdates:[withUpdates copy] all:all];
    });
  });
}

- (void)mainWindowController:(SWMainWindowController *)controller
      didConfirmUpdateForRepositories:(NSArray<SWRepository *> *)repositories
{
  NSString *sourcesDirectory = [kGershwinDeveloperPath stringByAppendingPathComponent:@"Library/Sources"];
  NSString *installScriptPath = [kGershwinDeveloperPath
    stringByAppendingPathComponent:@"Library/Scripts/install-system-domain.sh"];
  NSString *osSupportDirectory = [kGershwinDeveloperPath stringByAppendingPathComponent:@"Library/OSSupport"];

  _updateRepositories = repositories;

  NSMutableArray *repoDicts = [NSMutableArray array];
  for (SWRepository *repo in repositories) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:[repo name] forKey:@"Name"];
    if ([repo pin]) [dict setObject:[repo pin] forKey:@"Pin"];
    if ([repo restartRequired]) [dict setObject:@YES forKey:@"RestartRequired"];
    if ([repo targetBranch]) [dict setObject:[repo targetBranch] forKey:@"TargetBranch"];
    [repoDicts addObject:dict];
  }
  NSDictionary *args = @{
    @"Repositories": repoDicts,
    @"SourcesDirectory": sourcesDirectory,
    @"InstallScriptPath": installScriptPath,
    @"OSSupportDirectory": osSupportDirectory,
  };
  NSString *argsPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat:@"SoftwareUpdate-run-%d.plist", getpid()]];
  [args writeToFile:argsPath atomically:YES];

  // The repository names are already known, so the "repos" phase's sub-rows
  // do not have to wait for the helper process to report them.
  BOOL hasDeveloperPhase = [[[repositories firstObject] name] isEqualToString:@"gershwin-developer"];
  NSArray<SWRepository *> *phase3Repos = hasDeveloperPhase
    ? [repositories subarrayWithRange:NSMakeRange(1, [repositories count] - 1)]
    : repositories;

  NSMutableArray<SWProgressPhase *> *phases = [NSMutableArray array];
  if (hasDeveloperPhase) {
    SWProgressPhase *developerPhase = [[SWProgressPhase alloc] init];
    [developerPhase setIdentifier:@"developer"];
    [developerPhase setTitle:@"Update gershwin-developer"];
    [phases addObject:developerPhase];
  }
  SWProgressPhase *prereqsPhase = [[SWProgressPhase alloc] init];
  [prereqsPhase setIdentifier:@"prereqs"];
  [prereqsPhase setTitle:@"Install prerequisites"];
  [phases addObject:prereqsPhase];

  SWProgressPhase *reposPhase = [[SWProgressPhase alloc] init];
  [reposPhase setIdentifier:@"repos"];
  [reposPhase setTitle:@"Update repositories"];
  for (SWRepository *repo in phase3Repos) {
    SWProgressItem *item = [[SWProgressItem alloc] init];
    [item setTitle:[repo name]];
    [[reposPhase items] addObject:item];
  }
  [phases addObject:reposPhase];

  _updateUnitsTotal = (hasDeveloperPhase ? 1 : 0) + 1 /* prereqs counts as one unit */ + [phase3Repos count];
  _updateUnitsCompleted = 0;
  _updateResultRows = [NSMutableArray array];
  _updateStashConflicts = [NSMutableArray array];
  _updateCurrentPhase = nil;
  _updateWasStopped = NO;
  _updateFatalOccurred = NO;
  _updateFatalAlertShown = NO;

  if (!_progressWindow) {
    _progressWindow = [[SWProgressWindowController alloc] init];
    [_progressWindow setDelegate:self];
  }
  [_progressWindow setPhases:phases];
  [_progressWindow setOverallProgress:0.0];
  [_progressWindow setStatusText:@"Starting…"];
  [[_mainWindow window] orderOut:nil];
  [[_progressWindow window] makeKeyAndOrderFront:nil];

  NSString *executablePath = [[NSBundle mainBundle] executablePath];
  NSMutableArray *sudoArgs = [NSMutableArray arrayWithArray:GWSudoArgPrefix()];
  [sudoArgs addObjectsFromArray:@[executablePath, @"--run-update", argsPath]];

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:GWSudoPath()];
  [task setArguments:sudoArgs];

  NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
  [env setObject:@"/System/Library/Tools/SudoAskPass" forKey:@"SUDO_ASKPASS"];
  [env setObject:@"Software Update" forKey:@"ASKPASS_REQUESTER"];
  // apt-get install runs with no tty attached; without these, Debian's
  // debconf/needrestart can try to show an interactive prompt, which never
  // arrives and reads back here as a plain hang (readDataToEndOfFile just
  // waits on stdout that never closes). "-A -E" (see GWSudoArgPrefix)
  // preserves the environment through sudo, so this reaches apt-get even
  // though it is invoked several processes down (sudo -> re-exec'd helper
  // -> GWDebBackend's NSTask), none of which override it.
  [env setObject:@"noninteractive" forKey:@"DEBIAN_FRONTEND"];
  [env setObject:@"a" forKey:@"NEEDRESTART_MODE"];
  [task setEnvironment:env];

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  _updateTask = task;
  _updateArgsPath = argsPath;
  _updateReadHandle = [pipe fileHandleForReading];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(updateOutputAvailable:)
                                                name:NSFileHandleReadCompletionNotification
                                              object:_updateReadHandle];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(updateTaskDidTerminate:)
                                                name:NSTaskDidTerminateNotification
                                              object:task];
  [_updateReadHandle readInBackgroundAndNotify];

  @try {
    [task launch];
  } @catch (NSException *exception) {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[_progressWindow window] orderOut:nil];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Software Update could not start the privileged update."];
    [alert setInformativeText:[exception reason] ?: @""];
    [alert runModal];
    [self returnToMainWindow];
  }
}

- (void)returnToMainWindow
{
  NSMutableArray *withUpdates = [NSMutableArray array];
  for (SWRepository *repo in _allCheckedRepositories) {
    if ([repo hasUpdate]) [withUpdates addObject:repo];
  }
  [self showMainWindowWithUpdates:[withUpdates copy] all:_allCheckedRepositories];
}

#pragma mark - Privileged update run: event stream

- (void)updateOutputAvailable:(NSNotification *)notification
{
  NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
  if ([data length] > 0) {
    NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [chunk componentsSeparatedByString:@"\n"]) {
      if ([line length] > 0) [self handleUpdateEventLine:line];
    }
    [_updateReadHandle readInBackgroundAndNotify];
  }
}

- (void)refreshOverallProgress
{
  float fraction = (float)_updateUnitsCompleted / (float)MAX(_updateUnitsTotal, (NSUInteger)1);
  [_progressWindow setOverallProgress:fraction];
}

- (void)handleUpdateEventLine:(NSString *)line
{
  if ([line hasPrefix:@"LOG:"]) {
    [_logController appendLog:[[line substringFromIndex:4] stringByAppendingString:@"\n"]];

  } else if ([line hasPrefix:@"PHASE_DONE:"]) {
    NSString *identifier = [line substringFromIndex:11];
    [_progressWindow finishPhaseWithIdentifier:identifier];
    if (![identifier isEqualToString:@"repos"]) {
      _updateUnitsCompleted++;
      [self refreshOverallProgress];
    }

  } else if ([line hasPrefix:@"PHASE:"]) {
    _updateCurrentPhase = [line substringFromIndex:6];
    NSString *headline =
      [_updateCurrentPhase isEqualToString:@"developer"] ? @"Updating gershwin-developer…" :
      [_updateCurrentPhase isEqualToString:@"prereqs"] ? @"Installing prerequisites…" :
      @"Updating repositories…";
    [_progressWindow beginPhaseWithIdentifier:_updateCurrentPhase headline:headline];

  } else if ([line hasPrefix:@"PREREQ_MISSING:"]) {
    NSString *joined = [line substringFromIndex:15];
    NSArray *names = [joined length] > 0 ? [joined componentsSeparatedByString:@";"] : @[];
    SWProgressPhase *prereqsPhase = [_progressWindow phaseWithIdentifier:@"prereqs"];
    [[prereqsPhase items] removeAllObjects];
    for (NSString *name in names) {
      SWProgressItem *item = [[SWProgressItem alloc] init];
      [item setTitle:name];
      [[prereqsPhase items] addObject:item];
    }
    [_progressWindow setStatusText:[names count] > 0
      ? [NSString stringWithFormat:@"%lu package%@ to install", (unsigned long)[names count],
          [names count] == 1 ? @"" : @"s"]
      : @"No missing packages"];

  } else if ([line hasPrefix:@"PREREQ_PROGRESS:"]) {
    NSArray *parts = [[line substringFromIndex:17] componentsSeparatedByString:@":"];
    if ([parts count] >= 3) {
      NSUInteger idx = (NSUInteger)[parts[1] integerValue];
      [_progressWindow beginItemAtIndex:idx - 1 inPhaseWithIdentifier:@"prereqs" trailingText:@""];
      [_progressWindow setStatusText:[NSString stringWithFormat:@"Installing %@ (package %@ of %@)",
        parts[0], parts[1], parts[2]]];
    }

  } else if ([line hasPrefix:@"REPO:"]) {
    NSArray *parts = [[line substringFromIndex:5] componentsSeparatedByString:@":"];
    if ([parts count] >= 3) {
      NSUInteger idx = (NSUInteger)[parts[1] integerValue];
      NSString *phaseId = [_updateCurrentPhase isEqualToString:@"developer"] ? @"developer" : @"repos";
      [_progressWindow beginItemAtIndex:idx - 1 inPhaseWithIdentifier:phaseId trailingText:@""];
      [_progressWindow setStatusText:[NSString stringWithFormat:@"Checking out %@ (repository %@ of %@)",
        parts[0], parts[1], parts[2]]];
    }

  } else if ([line hasPrefix:@"STEP:"]) {
    NSString *verb = [line substringFromIndex:5];
    [_progressWindow setStatusText:verb];
    NSString *phaseId =
      [_updateCurrentPhase isEqualToString:@"developer"] ? @"developer" :
      [_updateCurrentPhase isEqualToString:@"prereqs"] ? @"prereqs" : @"repos";
    SWProgressPhase *phase = [_progressWindow phaseWithIdentifier:phaseId];
    NSUInteger runningIndex = NSNotFound;
    for (NSUInteger i = 0; i < [[phase items] count]; i++) {
      if ([[phase items][i] status] == SWProgressItemStatusRunning) runningIndex = i;
    }
    if (runningIndex != NSNotFound) {
      [_progressWindow beginItemAtIndex:runningIndex inPhaseWithIdentifier:phaseId trailingText:verb];
    }

  } else if ([line hasPrefix:@"DONE:"]) {
    NSArray *parts = [[line substringFromIndex:5] componentsSeparatedByString:@":"];
    if ([parts count] >= 2) {
      NSString *name = parts[0];
      SWRepositoryUpdateOutcome outcome = (SWRepositoryUpdateOutcome)[parts[1] integerValue];
      NSString *conflictsJoined = ([parts count] >= 3) ? parts[2] : @"";

      SWCompletionResultRow *row = [[SWCompletionResultRow alloc] init];
      [row setRepositoryName:name];
      [row setOutcome:outcome];
      for (SWRepository *repo in _updateRepositories) {
        if ([[repo name] isEqualToString:name]) [row setRestartRequired:[repo restartRequired]];
      }
      [_updateResultRows addObject:row];

      if (outcome == SWRepositoryUpdateOutcomeStashKept) {
        SWStashConflict *conflict = [[SWStashConflict alloc] init];
        [conflict setRepositoryName:name];
        [conflict setRepositoryPath:[[kGershwinDeveloperPath
          stringByAppendingPathComponent:@"Library/Sources"] stringByAppendingPathComponent:name]];
        [conflict setConflictedFiles:[conflictsJoined length] > 0
          ? [conflictsJoined componentsSeparatedByString:@";"] : @[]];
        [_updateStashConflicts addObject:conflict];
      }

      if ([_updateCurrentPhase isEqualToString:@"repos"]) {
        _updateUnitsCompleted++;
        [self refreshOverallProgress];
      }
    }

  } else if ([line hasPrefix:@"FATAL:"]) {
    [self handleUpdateFatal:[line substringFromIndex:6]];
  }
}

- (void)handleUpdateFatal:(NSString *)reason
{
  _updateFatalOccurred = YES;
  if ([reason hasPrefix:@"PREREQ:"]) {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"A required package could not be installed."];
    [alert setInformativeText:[reason substringFromIndex:7]];
    [alert addButtonWithTitle:@"OK"];
    _updateFatalAlertShown = YES;
    [alert runModal];
  }
  // A REPO: fatal failure already produced its own DONE row with a note
  // (build/install failed); the completion window explains it there.
}

- (void)updateTaskDidTerminate:(NSNotification *)notification
{
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:_updateReadHandle];
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSTaskDidTerminateNotification
                                                  object:_updateTask];
  [[NSFileManager defaultManager] removeItemAtPath:_updateArgsPath error:NULL];
  [[_progressWindow window] orderOut:nil];

  [SWStashAlertController presentIfNeededForConflicts:_updateStashConflicts];

  // "Installation complete." implies the run finished; a cancelled run, or
  // one that failed before anything was actually done (no repository even
  // got a DONE row), did not - showing it there would misreport the outcome.
  // A fatal failure that happened after some repositories were already
  // processed still gets the completion window, since it accurately lists
  // what did and did not happen.
  BOOL completelyErroredOut = _updateFatalOccurred && [_updateResultRows count] == 0;
  if (_updateWasStopped || completelyErroredOut) {
    if (_updateWasStopped) {
      NSAlert *alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Update stopped."];
      [alert setInformativeText:[_updateResultRows count] > 0
        ? @"Repositories already finished stay updated."
        : @"No repositories were changed."];
      [alert runModal];
    } else if (!_updateFatalAlertShown) {
      NSAlert *alert = [[NSAlert alloc] init];
      [alert setMessageText:@"Software Update could not complete the update."];
      [alert addButtonWithTitle:@"OK"];
      [alert runModal];
    }
    [self returnToMainWindow];
    return;
  }

  if (!_completionWindow) {
    _completionWindow = [[SWCompletionWindowController alloc] init];
    [_completionWindow setDelegate:self];
  }
  [_completionWindow setResults:_updateResultRows];
  [[_completionWindow window] makeKeyAndOrderFront:nil];
}

#pragma mark - SWProgressWindowControllerDelegate

- (void)progressWindowControllerDidClickStop:(SWProgressWindowController *)controller
{
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Stop updating?"];
  [alert setInformativeText:
    @"The repository currently being updated will be rolled back. Repositories already finished stay updated."];
  [alert addButtonWithTitle:@"Stop"];
  [alert addButtonWithTitle:@"Continue"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    _updateWasStopped = YES;
    [_updateTask terminate];
  }
}

#pragma mark - SWCompletionWindowControllerDelegate

- (void)completionWindowControllerDidClickRestart:(SWCompletionWindowController *)controller
{
  [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"LastUpdateDate"];
  [self restartSession];
}

- (void)completionWindowControllerDidClickLaterOrQuit:(SWCompletionWindowController *)controller
{
  [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"LastUpdateDate"];
  [NSApp terminate:nil];
}


// A full OS reboot, the same commands Menu.app's SystemActions tries (in
// order): systemd's systemctl, then the BSD/Linux reboot binary, then
// shutdown -r as a last resort. Deliberately independent of SystemActions
// itself, which lives inside Menu.app rather than a shared framework and
// also orchestrates asking every other app to quit first - more than this
// one-shot action after an update needs, and not worth the risk of
// refactoring a live desktop component's power-action code for it.
- (void)restartSession
{
  NSArray<NSArray<NSString *> *> *candidates = @[
    @[@"systemctl", @"reboot"],
    @[@"/sbin/reboot"],
    @[@"/usr/sbin/reboot"],
    @[@"/sbin/shutdown", @"-r", @"now"],
  ];
  for (NSArray<NSString *> *candidate in candidates) {
    NSString *launchPath = [candidate count] > 1 ? @"/usr/bin/env" : candidate[0];
    NSArray *arguments = [candidate count] > 1 ? candidate : @[];
    if ([candidate count] > 1) {
      // "systemctl reboot" via env so $PATH resolves it regardless of distro layout.
      launchPath = @"/usr/bin/env";
      arguments = candidate;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:candidate[0]] && [candidate count] == 1) {
      continue; // a bare absolute path that does not exist on this system
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:launchPath];
    [task setArguments:arguments];
    @try {
      [task launch];
      [NSApp terminate:nil];
      return;
    } @catch (NSException *exception) {
      continue; // try the next candidate
    }
  }

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:@"Software Update could not restart your computer."];
  [alert setInformativeText:@"Please restart it yourself to finish updating."];
  [alert runModal];
  [NSApp terminate:nil];
}

- (void)mainWindowControllerDidClickQuit:(SWMainWindowController *)controller
{
  [NSApp terminate:nil];
}

@end
