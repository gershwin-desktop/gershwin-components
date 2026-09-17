/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemandController - implementation.
 *
 * Supports two resource formats:
 *   1. Install.plist in plist format (preferred)
 *   2. packages (one-per-line text) + executable (single-line path) - legacy compat
 */

#import "OnDemandController.h"
#import "../GWOSDetector.h"
#import "../GWSystemCommandExecutor.h"

#pragma mark - Constants (derived from AppearanceMetrics.h)

static const CGFloat kWindowWidth = 400.0;
static const CGFloat kContentSideMargin = 24.0;
static const CGFloat kContentBottomMargin = 20.0;
static const CGFloat kContentTopMargin = 15.0;
static const CGFloat kButtonHeight = 20.0;
static const CGFloat kButtonMinWidth = 69.0;
static const CGFloat kSpinnerHeight = 24.0;
static const CGFloat kLabelHeight = 18.0;
static const CGFloat kGapTight = 8.0;
static const CGFloat kGapNormal = 16.0;

#pragma mark - OnDemandController

@implementation OnDemandController

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _pm = [[GWPackageManager alloc] initWithBackend:nil];
    }
  return self;
}

#pragma mark - Bundle Path Resolution

/// Resolve the actual .app bundle path from argv[0] so symlinked
/// placeholders load their own Resources/Install.plist rather than
/// the symlink target's bundle (OnDemand.app).
- (NSString *)_actualBundlePath
{
  NSString *arg0 = [[[NSProcessInfo processInfo] arguments] firstObject];
  if (arg0)
    {
      NSString *absPath = [arg0 stringByStandardizingPath];
      NSString *dir = absPath;
      while (dir && ![dir isEqualToString:@"/"])
        {
          if ([[dir pathExtension] isEqualToString:@"app"])
            return dir;
          dir = [dir stringByDeletingLastPathComponent];
        }
    }
  return [[NSBundle mainBundle] bundlePath];
}

#pragma mark - Bundle Setup

- (BOOL)setupFromBundle
{
  NSString *appPath = [self _actualBundlePath];
  _appName = [[appPath lastPathComponent] stringByDeletingPathExtension];
  NSLog(@"Placeholder -> setupFromBundle: appName=%@, appPath=%@", _appName, appPath);

  // Try plist format first
  NSString *plistPath = [appPath stringByAppendingPathComponent:@"Resources/Install.plist"];
  if (plistPath)
    {
      NSLog(@"Placeholder -> setupFromBundle: found plist at %@", plistPath);
      _spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                                       specType:GWPackageInstallSpecTypeInstall
                                                          error:nil];
      if (_spec)
        {
          _commandPath = [_spec postCommand];
          NSLog(@"Placeholder [OK] setupFromBundle: plist format resolved - packages=%@ command=%@",
                [_spec packages], _commandPath);
          return YES;
        }
      NSLog(@"Placeholder -> setupFromBundle: plist parse failed, trying legacy format");
    }

  // Fallback: legacy helloSystem text-file format
  NSString *execPath = [appPath stringByAppendingPathComponent:@"Resources/executable"];
  NSString *pkgPath = [appPath stringByAppendingPathComponent:@"Resources/packages"];
  NSLog(@"Placeholder -> setupFromBundle: checking legacy files - executable=%@ packages=%@",
        execPath, pkgPath);

  if (execPath)
    {
      _commandPath = [NSString stringWithContentsOfFile:execPath
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
      if (_commandPath)
        {
          // Strip comment after path
          NSRange hashRange = [_commandPath rangeOfString:@" #"];
          if (hashRange.location != NSNotFound)
            _commandPath = [_commandPath substringToIndex:hashRange.location];
          _commandPath = [_commandPath stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          NSLog(@"Placeholder -> setupFromBundle: resolved command from legacy file: %@", _commandPath);
        }
    }

  if (pkgPath)
    {
      NSString *pkgContent = [NSString stringWithContentsOfFile:pkgPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
      if (pkgContent)
        {
          NSMutableArray *pkgs = [NSMutableArray array];
          NSArray *lines = [pkgContent componentsSeparatedByString:@"\n"];
          for (NSString *line in lines)
            {
              NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceCharacterSet]];
              // Skip empty lines and comments
              if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"])
                continue;
              [pkgs addObject:trimmed];
            }
          NSLog(@"Placeholder -> setupFromBundle: parsed %lu packages from legacy file: %@",
                (unsigned long)[pkgs count], pkgs);
          // Create an in-memory plist dict with these packages
          NSDictionary *inlinePlist = @{
            @"packages": pkgs,
            @"postinstall_command": _commandPath ?: @"",
          };
          _spec = [[GWPackageInstallSpec alloc] initWithPlistAtPath:nil
                                                           specType:GWPackageInstallSpecTypeInstall
                                                              error:nil];
          // Manually set from dict since we don't have a plist file
          if (_spec)
            {
              // Direct property assignment via KVC for in-memory spec
              [_spec setValue:[inlinePlist[@"packages"] copy] forKey:@"packages"];
              [_spec setValue:[inlinePlist[@"postinstall_command"] copy] forKey:@"postCommand"];
            }
          BOOL ok = _spec != nil;
          NSLog(@"Placeholder -> setupFromBundle: legacy format -> %s (packages=%@, command=%@)",
                ok ? "YES" : "NO", [_spec packages], _commandPath);
          return ok;
        }
    }

  NSLog(@"Placeholder [FAIL] setupFromBundle: no install spec found in %@", appPath);
  return NO;
}

#pragma mark - Window Setup

- (void)showWindow
{
  CGFloat contentWidth = kWindowWidth - 2 * kContentSideMargin;

  // Layout bottom-up: cancel button, spinner, status label
  CGFloat y = kContentBottomMargin;                         // 20
  // Cancel button (centered)
  NSRect cancelRect = NSMakeRect(
    (kWindowWidth - kButtonMinWidth) / 2, y,
    kButtonMinWidth, kButtonHeight);                        // 69 x 20
  _cancelButton = [[NSButton alloc] initWithFrame:cancelRect];
  [_cancelButton setTitle:@"Cancel"];
  [_cancelButton setTarget:self];
  [_cancelButton setAction:@selector(cancelClicked:)];
  [[_window contentView] addSubview:_cancelButton];

  y += kButtonHeight + kGapNormal;                          // 20 + 16 = 36

  // Spinner (centered)
  NSRect spinRect = NSMakeRect(
    kContentSideMargin, y,
    contentWidth, kSpinnerHeight);                          // 352 x 24
  _spinner = [[NSProgressIndicator alloc] initWithFrame:spinRect];
  [_spinner setStyle:NSProgressIndicatorSpinningStyle];
  [_spinner setIndeterminate:YES];
  [_spinner setDisplayedWhenStopped:NO];
  [_spinner startAnimation:nil];
  [[_window contentView] addSubview:_spinner];

  y += kSpinnerHeight + kGapTight;                          // 24 + 8 = 32

  // Status label (centered)
  NSRect statusRect = NSMakeRect(
    kContentSideMargin, y,
    contentWidth, kLabelHeight);                            // 352 x 18
  _statusField = [[NSTextField alloc] initWithFrame:statusRect];
  [_statusField setStringValue:@"Preparing..."];
  [_statusField setBezeled:NO];
  [_statusField setDrawsBackground:NO];
  [_statusField setEditable:NO];
  [_statusField setSelectable:NO];
  [_statusField setAlignment:NSTextAlignmentCenter];
  [[_window contentView] addSubview:_statusField];

  // Create and show window with computed height
  NSRect rect = NSMakeRect(0, 0, kWindowWidth, y + kLabelHeight + kContentTopMargin);
  _window = [[NSWindow alloc] initWithContentRect:rect
                                        styleMask:NSWindowStyleMaskTitled
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  [_window setTitle:[NSString stringWithFormat:@"Installing %@", _appName]];
  [_window center];
  [_window setLevel:NSFloatingWindowLevel];
  [_window makeKeyAndOrderFront:nil];
}

#pragma mark - Progress Handler

- (void)installDidProgress:(float)progress message:(NSString *)message
{
  NSLog(@"Placeholder -> installDidProgress: %.0f%% - %@", progress * 100, message);
  dispatch_async(dispatch_get_main_queue(), ^{
    [_statusField setStringValue:message ?: @""];
  });
}

#pragma mark - Actions

- (void)cancelClicked:(id)sender
{
  [_cancelButton setEnabled:NO];
  [_statusField setStringValue:@"Cancelled"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    [NSApp terminate:nil];
  });
}

#pragma mark - Command Checking

- (BOOL)_commandExists:(NSString *)command
{
  if (!command || [command length] == 0)
    {
      NSLog(@"Placeholder -> _commandExists: (empty) -> NO");
      return NO;
    }

  if ([command hasPrefix:@"/"])
    {
      BOOL exists = [[NSFileManager defaultManager] isExecutableFileAtPath:command];
      NSLog(@"Placeholder -> _commandExists: absolute path %@ -> %s", command, exists ? "YES" : "NO");
      return exists;
    }

  // Search PATH via `which`
  id<GWSystemCommandExecutor> exec = [GWSystemCommandExecutor sharedExecutor];
  NSString *output = nil;
  int rc = [exec execute:@"/usr/bin/which" arguments:@[command] output:&output];
  BOOL found = (rc == 0 && output && [output length] > 0);
  NSLog(@"Placeholder -> _commandExists: which %@ -> %s (exit %d)", command, found ? "YES" : "NO", rc);
  return found;
}

/// Resolve a command to an absolute path. Returns nil on failure.
- (NSString *)_resolveCommandPath:(NSString *)command
{
  if ([command hasPrefix:@"/"])
    return command;

  id<GWSystemCommandExecutor> exec = [GWSystemCommandExecutor sharedExecutor];
  NSString *output = nil;
  int rc = [exec execute:@"/usr/bin/which" arguments:@[command] output:&output];
  if (rc == 0 && output)
    {
      NSString *path = [output stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([path length] > 0)
        return path;
    }
  return nil;
}

/// Execute a command via NSTask, inheriting stdio so stdout/stderr
/// and the exit code pass through to the caller.
/// Exit codes used by OnDemand/Placeholders:
///   0 = success
///   1 = setup/plist error
///   2 = command not found / can't resolve path
///   3 = installation failed
///   4 = NSTask execution exception
///   otherwise = exit code from the launched command (passed through)

/// Execute a command via NSTask, inheriting stdio so stdout/stderr
/// and the exit code pass through to the caller.
/// Returns: command's exit code (>= 0), -2 if not found, -4 on exception.
- (int)_executeCommand:(NSString *)command arguments:(NSArray<NSString *> *)args
{
  if (!command || [command length] == 0)
    {
      NSLog(@"Placeholder -> _executeCommand: (empty) -> exit -1");
      return -1;
    }

  NSString *path = [self _resolveCommandPath:command];
  if (!path)
    {
      NSLog(@"Placeholder [FAIL] _executeCommand: '%@' not found in PATH", command);
      return -2;
    }

  NSLog(@"Placeholder -> _executeCommand: %@ %@", path,
        [args count] > 0 ? [args componentsJoinedByString:@" "] : @"");

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:path];
  if ([args count] > 0)
    [task setArguments:args];
  // Pass through the parent's environment so the launched app sees
  // the same PATH, DISPLAY, etc.
  [task setEnvironment:[[NSProcessInfo processInfo] environment]];
  // Do NOT set standardOutput/standardError - leaving them unset
  // makes the child inherit the parent's stdio so output and exit
  // codes pass through to the caller.

  @try
    {
      [task launch];
      [task waitUntilExit];
      int status = [task terminationStatus];
      NSLog(@"Placeholder <- _executeCommand: %@ -> exit %d", path, status);
      return status;
    }
  @catch (NSException *e)
    {
      NSLog(@"Placeholder [FAIL] _executeCommand: exception running %@: %@", path, e);
      return -4;
    }
}

/// Map _executeCommand return value to an exit code and call exit().
- (void)_exitWithCommandStatus:(int)status command:(NSString *)command
{
  int code;
  if (status >= 0)
    code = status;                                   // pass through command's exit code
  else if (status == -2)
    code = 2;                                        // command not found
  else if (status == -4)
    code = 4;                                        // NSTask exception
  else
    code = 1;                                        // unknown error

  NSLog(@"Placeholder -> _exitWithCommandStatus: %d -> exit(%d)", status, code);
  exit(code);
}

#pragma mark - Direct Launch (no GUI)

- (BOOL)commandIsAvailable
{
  NSString *command = _commandPath;
  return command ? [self _commandExists:command] : NO;
}

- (BOOL)launchAndExit
{
  NSString *command = _commandPath;
  NSArray *args = [_spec postCommandArguments];
  NSLog(@"Placeholder -> launchAndExit: %@ %@", command,
        [args count] > 0 ? [args componentsJoinedByString:@" "] : @"");
  int status = [self _executeCommand:command arguments:args];
  [self _exitWithCommandStatus:status command:command];
  return YES; // unreachable
}

#pragma mark - Main Workflow (install + launch)

- (void)performInstallAndLaunch
{
  NSArray *packages = [_spec packages];
  NSString *command = _commandPath;
  NSLog(@"Placeholder -> performInstallAndLaunch: BEGIN (command=%@, packages=%@)",
        command, packages);

  // Install packages
  if (packages && [packages count] > 0)
    {
      NSLog(@"Placeholder -> [Step 1/2] Installing packages: %@", packages);
      [_statusField setStringValue:@"Installing..."];

      NSError *error = nil;
      BOOL success = [_pm installPackages:packages
                           localFilePaths:nil
                                progress:self
                                   error:&error];

      if (!success)
        {
          NSString *msg = error
            ? [error localizedDescription]
            : @"Installation failed";
          NSLog(@"Placeholder [FAIL] [Step 1/2] Installation FAILED: %@", msg);
          [self _showError:msg];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
            exit(3);
          });
          return;
        }
      NSLog(@"Placeholder [OK] [Step 1/2] Installation succeeded");
    }
  else
    {
      NSLog(@"Placeholder -> [Step 1/2] No packages to install");
    }

  // Execute the command (inherits stdio, passes through exit code)
  if (command)
    {
      NSLog(@"Placeholder -> [Step 2/2] Executing command: %@", command);
      [_statusField setStringValue:@"Launching..."];
      [_spinner stopAnimation:nil];

      int status = [self _executeCommand:command arguments:[_spec postCommandArguments]];
      if (status != 0)
        {
          NSLog(@"Placeholder [FAIL] [Step 2/2] Execution FAILED: %@ (status %d)", command, status);
          [self _showError:[NSString stringWithFormat:
                            @"Package installed but failed to launch %@", command]];
          [self _exitWithCommandStatus:status command:command];
          return;
        }

      NSLog(@"Placeholder [OK] [Step 2/2] Execution succeeded (exit %d), exiting", status);
      [self _exitWithCommandStatus:status command:command];
    }
  else
    {
      NSLog(@"Placeholder -> performInstallAndLaunch: no postinstall command, done");
      [_statusField setStringValue:@"Installation complete"];
      [_spinner stopAnimation:nil];
      exit(0);
    }
}

#pragma mark - Error Display

- (void)_showError:(NSString *)message
{
  NSLog(@"Placeholder: Error - %@", message);
  [_spinner stopAnimation:nil];
  [_statusField setStringValue:[NSString stringWithFormat:@"Error: %@", message]];
  [_cancelButton setTitle:@"Quit"];
  [_cancelButton setEnabled:YES];
  [_cancelButton setAction:@selector(quitClicked:)];
}

- (void)quitClicked:(id)sender
{
  [NSApp terminate:nil];
}

#pragma mark - NSApplicationDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
  return YES;
}

@end
