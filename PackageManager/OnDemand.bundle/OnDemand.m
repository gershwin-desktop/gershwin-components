/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemand — GNUstep bundle loaded into every GUI app via GSAppKitUserBundles.
 * When an app launches, checks whether it ships a Resources/Dependencies.plist
 * and offers to install missing packages directly via the system package manager.
 * A preference pane that ships one is checked the same way when it is selected.
 */

#import "OnDemand.h"
#import <objc/runtime.h>
#import <PackageManager/GWPackageInstallSpec.h>
#import <PackageManager/GWPackageManager.h>
#import <PackageManager/ODProgressWindow.h>

/* The two NSPreferencePane methods used here; the bundle does not link the
   PreferencePanes library, which only some hosts have. */
@protocol ODPreferencePane
- (NSBundle *)bundle;
- (void)didSelect;
@end

/* Receives the package manager's progress on its worker thread. */
@interface ODInstallObserver : NSObject <GWInstallProgressHandler>
@property (atomic, copy) NSString *status;
@end

@implementation ODInstallObserver
- (void)installDidProgress:(float)progress message:(NSString *)message
{
  if ([message length] > 0)
    self.status = message;
}

- (void)installDidOutputLine:(NSString *)line
{
  NSString *trimmed = [line stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed length] > 0)
    self.status = trimmed;
}
@end

@interface OnDemand ()
+ (void)_appDidFinishLaunch:(NSNotification *)n;
+ (NSArray *)_missingPackagesFromArray:(NSArray *)packages;
+ (void)_showErrorAlert:(NSString *)title detail:(NSString *)detail;
+ (void)_runInstallWithPackages:(NSArray *)packages;
+ (void)_installPaneHook;
+ (BOOL)_showInstallAlertForAppName:(NSString *)appName
                    missingPackages:(NSArray *)missing
                         bundlePath:(NSString *)bundlePath;
+ (BOOL)_offerForBundleAtPath:(NSString *)bundlePath;
+ (void)_reportPackagesStillMissingFromPlistAtPath:(NSString *)plistPath;
+ (void)_paneDidSelect:(id<ODPreferencePane>)pane;
@end

/* Bundles that were offered their packages: asked once per run of the host,
   whatever the answer.  An install that fails, or that the system does not
   notice, would otherwise be offered again on the re-selection that follows it,
   for ever. */
static NSMutableSet *_askedBundlePaths = nil;

static IMP _originalPaneDidSelect = NULL;

static void paneDidSelect(id pane, SEL _cmd)
{
  ((void (*)(id, SEL))(void *)_originalPaneDidSelect)(pane, _cmd);
  [OnDemand _paneDidSelect:pane];
}

static ODProgressWindow *_progressWin = nil;

@implementation OnDemand

+ (void)load
{
  [[NSNotificationCenter defaultCenter]
    addObserver:[self class]
    selector:@selector(_appDidFinishLaunch:)
    name:NSApplicationDidFinishLaunchingNotification
    object:nil];
  NSLog(@"OnDemand bundle: registered for app-launch notifications");
}

+ (void)_appDidFinishLaunch:(NSNotification *)n
{
  NSBundle *appBundle = [NSBundle mainBundle];
  if (!appBundle) return;

  NSString *bundlePath = [appBundle bundlePath];

  NSString *selfBundle = [[NSBundle bundleForClass:[self class]] bundlePath];
  if ([bundlePath isEqualToString:selfBundle] ||
      [bundlePath hasPrefix:@"/System/Applications/Utilities/OnDemand"])
    return;

  [self _installPaneHook];

  /* Let the app finish coming up before a dialog appears. */
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self _offerForBundleAtPath:bundlePath];
  });
}

/* SystemPreferences loads every pane's class at startup, only to ask whether
   the pane is compatible, so the moment to offer a pane's packages is when the
   user selects it.  Every pane calls through to NSPreferencePane's -didSelect. */
+ (void)_installPaneHook
{
  Class paneClass = NSClassFromString(@"NSPreferencePane");
  Method method = paneClass ? class_getInstanceMethod(paneClass, @selector(didSelect)) : NULL;
  if (method == NULL || _originalPaneDidSelect != NULL)
    return;
  _originalPaneDidSelect = method_setImplementation(method, (IMP)(void *)paneDidSelect);
}

+ (void)_paneDidSelect:(id<ODPreferencePane>)pane
{
  NSString *bundlePath = [[pane bundle] bundlePath];
  if (bundlePath == nil)
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([self _offerForBundleAtPath:bundlePath])
      {
        /* The pane looked for what it needs before it was there. */
        [pane didSelect];
      }
  });
}

/* YES when the user had packages installed. */
+ (BOOL)_offerForBundleAtPath:(NSString *)bundlePath
{
  NSString *depsPlist = [bundlePath stringByAppendingPathComponent:
                           @"Resources/Dependencies.plist"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:depsPlist])
    return NO;

  NSLog(@"OnDemand bundle: found Dependencies.plist in %@", bundlePath);

  if ([_askedBundlePaths containsObject:bundlePath])
    return NO;

  NSString *appName = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
  NSArray *missing = [self missingPackagesFromPlistAtPath:depsPlist];

  if ([missing count] == 0)
    {
      NSLog(@"OnDemand bundle: all dependencies satisfied for %@", appName);
      return NO;
    }

  NSLog(@"OnDemand bundle: missing packages for %@: %@", appName, missing);

  BOOL installed = [self _showInstallAlertForAppName:appName missingPackages:missing
                                          bundlePath:bundlePath];
  if (installed)
    [self _reportPackagesStillMissingFromPlistAtPath:depsPlist];
  return installed;
}

/* The install went through but the system does not list the packages: say so
   instead of asking again. */
+ (void)_reportPackagesStillMissingFromPlistAtPath:(NSString *)plistPath
{
  NSArray *stillMissing = [self missingPackagesFromPlistAtPath:plistPath];
  if ([stillMissing count] == 0)
    return;
  NSLog(@"OnDemand bundle: still missing after the install: %@", stillMissing);
  [self _showErrorAlert:@"Software Still Missing"
                 detail:[NSString stringWithFormat:
    @"The installation finished, but the system still does not list:\n\n• %@",
    [stillMissing componentsJoinedByString:@"\n• "]]];
}

+ (NSArray *)missingPackagesFromPlistAtPath:(NSString *)plistPath
{
  /* The framework resolves the plist: the packages are named per
     distribution, so the entry is picked by what this machine really is,
     not by what it was compiled on. */
  NSError *specError = nil;
  GWPackageInstallSpec *spec =
    [[GWPackageInstallSpec alloc] initWithPlistAtPath:plistPath
                                             specType:GWPackageInstallSpecTypeInstall
                                                error:&specError];
  if (!spec)
    {
      NSLog(@"OnDemand bundle: cannot read %@: %@", plistPath, specError);
      return @[];
    }
  return [self _missingPackagesFromArray:[spec packages]];
}

+ (BOOL)installPackagesFromPlistAtPath:(NSString *)plistPath title:(NSString *)title
{
  NSArray *missing = [self missingPackagesFromPlistAtPath:plistPath];
  if ([missing count] == 0)
    return YES;
  if (![self _showInstallAlertForAppName:title missingPackages:missing bundlePath:nil])
    return NO;
  NSArray *stillMissing = [self missingPackagesFromPlistAtPath:plistPath];
  if ([stillMissing count] > 0)
    [self _reportPackagesStillMissingFromPlistAtPath:plistPath];
  return [stillMissing count] == 0;
}

+ (BOOL)_showInstallAlertForAppName:(NSString *)appName
                    missingPackages:(NSArray *)missing
                         bundlePath:(NSString *)bundlePath
{
  if (bundlePath != nil)
    {
      if (_askedBundlePaths == nil)
        _askedBundlePaths = [NSMutableSet set];
      [_askedBundlePaths addObject:bundlePath];
    }

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:
    @"%@ needs additional software to run.", appName]];
  [alert setInformativeText:[NSString stringWithFormat:
    @"The following packages are missing and need to be installed:\n\n• %@\n\n"
    @"Would you like to install them now?",
    [[missing copy] componentsJoinedByString:@"\n• "]]];
  [alert addButtonWithTitle:@"Install"];
  [alert addButtonWithTitle:@"Skip"];

  NSInteger result = [alert runModal];
  if (result != NSAlertFirstButtonReturn)
    {
      NSLog(@"OnDemand bundle: user skipped installation for %@", appName);
      return NO;
    }

  [self _runInstallWithPackages:missing];
  return YES;
}

+ (void)_runInstallWithPackages:(NSArray *)packages
{
  NSLog(@"OnDemand bundle: installing packages: %@", packages);

  /* The install itself is PackageManager's: it knows every supported system's
     package tool, finishes an interrupted install first, and runs the tools in
     a fixed locale. */
  _progressWin = [[ODProgressWindow alloc] initWithTitle:@"Installing..."
                                                  message:@"Installing required packages..."
                                                 packages:packages];
  /* The static reference owns the window; a window that releases itself when
     closed would be freed under it. */
  [_progressWin setReleasedWhenClosed:NO];
  [_progressWin showWindow:nil];

  ODInstallObserver *observer = [[ODInstallObserver alloc] init];
  __block BOOL finished = NO;
  __block BOOL succeeded = NO;
  __block NSError *installError = nil;
  __block NSString *failureDetail = nil;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    GWPackageManager *manager = [GWPackageManager sharedManager];
    NSError *error = nil;
    BOOL ok = [manager installPackages:packages localFilePaths:@[] progress:observer error:&error];
    installError = error;
    failureDetail = [manager capturedErrorOutput];
    succeeded = ok;
    finished = YES;
  });

  /* AppKit events are only dispatched by the application's own event loop, so
     it is pumped here: spinning the plain run loop left the window unpainted. */
  NSString *shownStatus = nil;
  while (!finished)
    {
      NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (event != nil)
        [NSApp sendEvent:event];
      NSString *status = observer.status;
      if (status != nil && ![status isEqualToString:shownStatus])
        {
          [_progressWin setStatus:status];
          shownStatus = status;
        }
      [_progressWin displayIfNeeded];
    }

  [_progressWin close];
  _progressWin = nil;

  if (!succeeded)
    {
      NSLog(@"OnDemand bundle: install failed: %@", installError);
      NSString *detail = [GWPackageManager friendlyErrorMessageForError:installError
                                                                appName:@"the software"];
      if ([failureDetail length] > 0)
        detail = [detail stringByAppendingFormat:@"\n\n%@",
                   [failureDetail substringToIndex:MIN([failureDetail length], 500)]];
      [self _showErrorAlert:@"Installation Failed" detail:detail];
    }
  else
    {
      NSLog(@"OnDemand bundle: install succeeded");
    }
}

+ (void)_showErrorAlert:(NSString *)title detail:(NSString *)detail
{
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:title];
  [alert setInformativeText:detail];
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

+ (NSArray *)_missingPackagesFromArray:(NSArray *)packages
{
  return [[GWPackageManager sharedManager] missingPackagesFrom:packages];
}

@end
