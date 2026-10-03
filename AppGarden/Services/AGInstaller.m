/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGInstaller.h"
#import "AGInstallRegistry.h"
#import "AGInstallTask.h"
#import "AGDownloadResolver.h"
#import "AGApp.h"
#import "AGCatalog.h"
#import <AppKit/AppKit.h>
#import <PackageManager/GWAppImageDownloader.h>
#import <PackageManager/GWPackageManager.h>

NSString *const AGInstallerTaskDidChangeNotification =
    @"AGInstallerTaskDidChangeNotification";
NSString *const AGInstallerInstalledSetDidChangeNotification =
    @"AGInstallerInstalledSetDidChangeNotification";

/* The desktop regenerates its list of launchable applications with this
 * tool, which is the documented way a file in the framework's directory
 * becomes reachable by name (make_services/README.md). */
static NSString *const AGMakeServicesPath = @"/System/Library/Tools/make_services";

static NSString *const AGInstallerErrorDomain =
    @"io.github.gershwin-desktop.AppGarden.AGInstaller";

enum {
  AGInstallerErrorRemove = 1,   // the AppImage could not be deleted
  AGInstallerErrorLaunch,       // the AppImage could not be started at all
  AGInstallerErrorReveal        // the file manager would not show the file
};

static NSError *AGInstallerError(NSInteger code, NSString *text)
{
  return [NSError errorWithDomain:AGInstallerErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: text }];
}

/*
 * The file manager's Distributed Objects name. GNUstep registers an
 * application's services connection under the application's name with the
 * services listener as its root object, and that listener forwards any
 * selector the application delegate answers to - and the delegate of
 * Workspace is its own singleton, which implements
 * -selectFile:inFileViewerRootedAtPath: (Workspace/WorkspaceApplication.m).
 * The only selector filter there is, the GSPermittedMessages default, is not
 * set on this desktop, so this one is not filtered out.
 */
static NSString *const AGWorkspaceDOName = @"Workspace";

/* What AppGarden asks Workspace for over that connection. Declared here
 * because the connection is private to this class; the signature has to match
 * Workspace's own method exactly, or the reply cannot be decoded. */
@protocol AGWorkspaceFileRevealing <NSObject>
- (BOOL)selectFile:(NSString *)fullPath inFileViewerRootedAtPath:(NSString *)rootFullpath;
@end

/* What AppGarden asks Workspace for when the user removes an installed
 * application. Workspace declares the same method on its own
 * @protocol WorkspaceAppProtocol, which lives in a source file of
 * gershwin-workspace rather than in an installed framework header, so the
 * one selector needed here is declared here; the signature has to match
 * Workspace's exactly, or the call cannot be decoded.
 * alreadyConfirmed: passes along the fact that the controller has already
 * asked the user, so Workspace does not ask a second time. */
@protocol AGWorkspaceTrashing <NSObject>
- (oneway void)trashExternalPaths:(NSArray *)paths
                 alreadyConfirmed:(BOOL)alreadyConfirmed;
@end

/* Both notifications are promised on the main thread, and every caller of
 * these two helpers is already inside a main-queue block. */
static void AGPostTaskChange(AGInstallTask *task)
{
  [[NSNotificationCenter defaultCenter]
      postNotificationName:AGInstallerTaskDidChangeNotification
                    object:task];
}

static void AGPostInstalledSetChange(AGInstaller *installer)
{
  [[NSNotificationCenter defaultCenter]
      postNotificationName:AGInstallerInstalledSetDidChangeNotification
                    object:installer];
}

@interface AGInstaller ()
- (void)runInstallForTask:(AGInstallTask *)task app:(AGApp *)app;
- (void)refreshServicesForApp:(AGApp *)app;
- (void)runMakeServices;
- (BOOL)askWorkspaceToTrashPath:(NSString *)path error:(NSError **)error;
@end

@implementation AGInstaller
{
  NSOperationQueue *_queue;
  NSMutableDictionary<NSString *, AGInstallTask *> *_tasks;
  NSString *_architecture;
  NSMutableSet<NSString *> *_servicesRefreshed;
  GWAppImageDownloader *_downloader;
}

- (instancetype)initWithRegistry:(AGInstallRegistry *)registry
{
  NSParameterAssert(registry != nil);

  self = [super init];
  if (self)
    {
      _registry = registry;
      _queue = [[NSOperationQueue alloc] init];
      /* One download at a time keeps bandwidth predictable and progress
       * readable; a second Get click on another app queues behind the first
       * and its button reads Waiting. */
      [_queue setMaxConcurrentOperationCount:1];
      _tasks = [NSMutableDictionary dictionary];
      _servicesRefreshed = [NSMutableSet set];
      _downloader = [[GWAppImageDownloader alloc] init];
      /* Read once at startup: the resolver is a pure function of app plus
       * architecture, so the uname behind it runs a single time per launch. */
      _architecture = [[AGDownloadResolver currentArchitecture] copy];
    }
  return self;
}

/* Defined only so the interface's NS_UNAVAILABLE entry has a body: the
 * attribute keeps callers out, while the route to the designated initializer
 * keeps the compiler's initializer chain well formed and trips the registry
 * assert if anything ever slips through. */
- (instancetype)init
{
  return [self initWithRegistry:nil];
}

#pragma mark - State queries

- (AGInstallState)stateForApp:(AGApp *)app
{
  NSString *name = [app name];
  if (name == nil)
    return AGInstallStateNotInstalled;

  AGInstallRegistry *registry = [self registry];
  if ([registry entryForName:name] != nil)
    {
      /* existing, not the download path alone: an install that predates the
       * move of the download folder is still where it was downloaded to, and
       * that is where it is found, removed and revealed. */
      NSString *path = [GWAppImageDownloader existingLauncherPathForAppName:name];
      NSFileManager *fm = [NSFileManager defaultManager];
      if ([fm isExecutableFileAtPath:path])
        return AGInstallStateInstalled;

      if (![fm fileExistsAtPath:path])
        {
          /* The file was deleted outside the app: the registry entry and a
           * finished task that both promise it are stale, and keeping them
           * would draw an Open button for a file that is not there. Dropping
           * them on this query is state reconciliation, not an error path. */
          [registry removeEntryForName:name];
          @synchronized (self)
            {
              [_tasks removeObjectForKey:name];
            }
        }
    }

  AGInstallTask *task = [self taskForApp:app];
  if (task != nil)
    {
      switch ([task state])
        {
          case AGInstallTaskStateWaiting:
          case AGInstallTaskStateDownloading:
            return AGInstallStateDownloading;
          case AGInstallTaskStateFailed:
            return AGInstallStateFailed;
          case AGInstallTaskStateDone:
          case AGInstallTaskStateCancelled:
            /* Done without an installed file was reconciled above; cancelled
             * means the user asked to be back at the start. */
            break;
        }
    }
  return AGInstallStateNotInstalled;
}

- (AGInstallTask *)taskForApp:(AGApp *)app
{
  NSString *name = [app name];
  if (name == nil)
    return nil;
  @synchronized (self)
    {
      return [_tasks objectForKey:name];
    }
}

- (NSArray<AGApp *> *)installedAppsFromCatalog:(AGCatalog *)catalog
{
  if (catalog == nil)
    return [NSArray array];   /* the catalog-less pass below would drop every entry */

  AGInstallRegistry *registry = [self registry];
  [registry reconcile];

  NSMutableArray<AGApp *> *installed = [NSMutableArray array];
  for (AGApp *app in [catalog apps])
    {
      if ([registry entryForName:[app name]] != nil)
        [installed addObject:app];
    }

  /* The same reconcile pass also drops entries the catalog no longer carries:
   * they cannot be shown as cards, so keeping them would only let the
   * registry drift away from what the Installed page displays. */
  for (NSString *name in [registry installedNames])
    {
      if ([catalog appNamed:name] == nil)
        [registry removeEntryForName:name];
    }
  return installed;
}

#pragma mark - Installing

- (AGInstallTask *)installApp:(AGApp *)app
{
  AGInstallTask *task = [[AGInstallTask alloc] initWithApp:app];

  /* Published synchronously: installApp: returns immediately and the button
   * re-reads the state right away, so the task must be findable before the
   * operation ever runs. */
  NSString *name = [app name];
  @synchronized (self)
    {
      if (name != nil)
        [_tasks setObject:task forKey:name];
    }

  AGInstaller *installer = self;
  NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
    [installer runInstallForTask:task app:app];
  }];
  [_queue addOperation:operation];
  return task;
}

/* Runs on the serial install queue. */
- (void)runInstallForTask:(AGInstallTask *)task app:(AGApp *)app
{
  if ([task state] == AGInstallTaskStateCancelled)
    return;   /* cancelled while still queued behind another download */

  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if ([task state] == AGInstallTaskStateWaiting)
      {
        task.state = AGInstallTaskStateDownloading;
        AGPostTaskChange(task);
      }
  }];

  NSString *name = [app name];
  id payload = nil;
  AGDownloadKind kind = [AGDownloadResolver kindForApp:app
                                         architecture:_architecture
                                              payload:&payload];
  /* WebPageOnly and None never reach here: the button opens the download
   * page for them, so asking to install one is a programming error. */
  NSAssert(kind == AGDownloadKindGitHubLatestRelease ||
           kind == AGDownloadKindKDEFileListing ||
           kind == AGDownloadKindDirectURL,
           @"AGInstaller may only be asked to install what the Get button downloads");

  NSError *error = nil;
  BOOL succeeded = NO;
  if (kind == AGDownloadKindGitHubLatestRelease)
    {
      /* The underscore conversion into the file name happens inside the
       * downloader, so it is the feed name that goes over. The task's
       * conformance to the progress protocol lives in its own .m, hence the
       * cast that names the protocol at the call site. */
      succeeded = [_downloader downloadAppImageFromGitHubRepo:(NSString *)payload
                                                       appName:name
                                                      progress:(id<GWInstallProgressHandler>)task
                                                         error:&error];
    }
  else if (kind == AGDownloadKindKDEFileListing)
    {
      /* A download.kde.org application directory, not a file: the framework
       * reads the index, walks to the newest version that ships an AppImage
       * and picks this machine's build out of it. */
      succeeded = [_downloader downloadAppImageFromKDEListingURL:
                    [(NSURL *)payload absoluteString]
                                                    appName:name
                                                   progress:(id<GWInstallProgressHandler>)task
                                                      error:&error];
    }
  else if (kind == AGDownloadKindDirectURL)
    {
      succeeded = [_downloader downloadAppImageFromURL:[(NSURL *)payload absoluteString]
                                               appName:name
                                              progress:(id<GWInstallProgressHandler>)task
                                                 error:&error];
    }
  /* The assert above covers the other two kinds; in a build without
   * assertions this falls through as a plain failure instead of handing the
   * downloader a payload of the wrong type. */

  if ([task state] == AGInstallTaskStateCancelled)
    return;   /* the user gave up mid-flight; the next Get downloads again */

  if (succeeded)
    {
      NSString *path = [GWAppImageDownloader launcherPathForAppName:name];
      [[self registry] recordApp:app path:path];
      /* After the file exists, on this background operation, and once per
       * install: the desktop only learns about the new application from
       * this refresh, and launchApp: should not have to repeat it. */
      [self refreshServicesForApp:app];

      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if ([task state] == AGInstallTaskStateCancelled)
          return;
        task.state = AGInstallTaskStateDone;
        AGPostTaskChange(task);
        AGPostInstalledSetChange(self);
      }];
    }
  else
    {
      NSError *failure = error;
      [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if ([task state] == AGInstallTaskStateCancelled)
          return;
        /* The setter is where a bare GitHub rate limit failure becomes text
         * that names the cause; see AGInstallTask.m. */
        task.error = failure;
        task.state = AGInstallTaskStateFailed;
        AGPostTaskChange(task);
      }];
    }
}

- (void)cancelTask:(AGInstallTask *)task
{
  if (task == nil)
    return;

  /* The state change hops like every other one, and both ends of the running
   * operation re-read the state: a task still queued is skipped when its
   * operation starts, and a download that finishes anyway finds the task
   * already ended and leaves it alone. */
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    AGInstallTaskState state = [task state];
    if (state != AGInstallTaskStateWaiting && state != AGInstallTaskStateDownloading)
      return;
    task.state = AGInstallTaskStateCancelled;
    AGPostTaskChange(task);
  }];
}

#pragma mark - Removing

- (BOOL)removeApp:(AGApp *)app error:(NSError **)error
{
  if (error != NULL)
    *error = nil;

  /* The confirmation dialog belongs to the controller: this method only
   * carries out the removal the user already agreed to. */
  NSString *path = [GWAppImageDownloader existingLauncherPathForAppName:[app name]];
  if (path != nil
      && [[NSFileManager defaultManager] fileExistsAtPath:path]
      && ![self askWorkspaceToTrashPath:path error:error])
    {
      /* The launcher is still exactly where it was, so the entry that
       * promised it and the card that shows it both stay as they are. */
      return NO;
    }

  /* The file is gone (or was already, or is on its way to the Trash), so
   * the entry that promised it and the task that finished it both go with
   * it. */
  [[self registry] removeEntryForName:[app name]];
  @synchronized (self)
    {
      [_tasks removeObjectForKey:[app name]];
    }
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    AGPostInstalledSetChange(self);
  }];
  return YES;
}

/* Hands the launcher to Workspace, which moves it to the Trash.  This is
 * deliberately not a local -removeItemAtPath: any more: a deleted AppImage
 * is gone for good, a trashed one can be put back, and going through
 * Workspace means the icon also flies into the Trash icon on the Dock when
 * a window is showing it, the way a drag there would look.
 *
 * Workspace's call is oneway, so this can report only whether the request
 * could be made at all, not its outcome - which is why it does not time the
 * connection out the way -revealApp: does for its reply.  If the file
 * manager is not running, the launcher is left alone and the error says so,
 * rather than falling back to deleting it for good behind the user's back. */
- (BOOL)askWorkspaceToTrashPath:(NSString *)path error:(NSError **)error
{
  NSString *failure = nil;

  @try
    {
      NSDistantObject *workspace =
          [NSConnection rootProxyForConnectionWithRegisteredName:AGWorkspaceDOName
                                                            host:nil];
      if (workspace == nil)
        {
          failure = NSLocalizedString(@"The file manager is not running.", @"");
        }
      else
        {
          [workspace setProtocolForProxy:@protocol(AGWorkspaceTrashing)];
          /* YES: the controller has just asked the user with its own
           * "Remove %@?" dialog, so Workspace must not ask again. */
          [(id<AGWorkspaceTrashing>)workspace
              trashExternalPaths:[NSArray arrayWithObject:path]
                  alreadyConfirmed:YES];
        }
    }
  @catch (NSException *exception)
    {
      failure = [NSString stringWithFormat:
          NSLocalizedString(@"The file manager could not be reached: %@", @""),
          [exception reason]];
    }

  if (failure != nil)
    {
      if (error != NULL)
        *error = AGInstallerError(AGInstallerErrorRemove, failure);
      return NO;
    }
  return YES;
}

#pragma mark - Launching

- (BOOL)launchApp:(AGApp *)app error:(NSError **)error
{
  if (error != NULL)
    *error = nil;

  NSString *name = [app name];
  BOOL refreshed;
  @synchronized (self)
    {
      refreshed = (name != nil) && [_servicesRefreshed containsObject:name];
    }
  /* The services refresh has to have happened before the workspace lookup
   * can answer for the new application; an install in this session ran it on
   * its background operation already, while an app that was installed in an
   * earlier session runs it here, once, waiting for it to finish. */
  if (!refreshed)
    [self refreshServicesForApp:app];

  if ([[NSWorkspace sharedWorkspace] launchApplication:[app displayName]])
    return YES;

  /* WHY the direct run exists: the workspace lookup answers out of the
   * services cache, while a plain executable can always be started, so an
   * AppImage the cache does not know about opens this way instead of being
   * reported as unlaunchable. An error is reported only if this raises. */
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:[GWAppImageDownloader existingLauncherPathForAppName:name]];
  [task setArguments:@[]];
  [task setCurrentDirectoryPath:NSHomeDirectory()];
  @try
    {
      [task launch];
    }
  @catch (NSException *exception)
    {
      if (error != NULL)
        *error = AGInstallerError(AGInstallerErrorLaunch, [NSString stringWithFormat:
            NSLocalizedString(@"Could not start %@: %@", @""),
            [app displayName], [exception reason]]);
      return NO;
    }
  return YES;
}

#pragma mark - Revealing

/*
 * What the Open button runs: not starting the application, but asking the
 * file manager over Distributed Objects to show the file it installed, the
 * same thing "Show in File Viewer" does elsewhere on the desktop. The file
 * manager is the Workspace application; the connection is looked up by its
 * registered name, so nothing is hard-coded beyond that name, and a file
 * manager that is not running is reported rather than silently ignored.
 */
- (BOOL)revealApp:(AGApp *)app error:(NSError **)error
{
  if (error != NULL)
    *error = nil;

  NSString *name = [app name];
  NSString *path = (name != nil)
      ? [GWAppImageDownloader existingLauncherPathForAppName:name] : nil;
  if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
    {
      if (error != NULL)
        *error = AGInstallerError(AGInstallerErrorReveal, [NSString stringWithFormat:
            NSLocalizedString(@"%@ is no longer on disk.", @""),
            [app displayName]]);
      return NO;
    }

  BOOL shown = NO;
  NSString *failure = NSLocalizedString(@"The file manager did not show the file.", @"");
  @try
    {
      NSDistantObject *workspace =
          [NSConnection rootProxyForConnectionWithRegisteredName:AGWorkspaceDOName
                                                            host:nil];
      if (workspace == nil)
        {
          failure = NSLocalizedString(@"The file manager is not running.", @"");
        }
      else
        {
          /* Opening a viewer can take a moment the first time, and a file
           * manager that never answers must cost a dialog, not a window that
           * sits there unresponsive: the same 5 second bound the desktop
           * puts on its own workspace calls. */
          NSConnection *connection = [workspace connectionForProxy];
          [connection setRequestTimeout:5.0];
          [connection setReplyTimeout:5.0];
          [workspace setProtocolForProxy:@protocol(AGWorkspaceFileRevealing)];
          shown = [(id<AGWorkspaceFileRevealing>)workspace
              selectFile:path
              inFileViewerRootedAtPath:[path stringByDeletingLastPathComponent]];
        }
    }
  @catch (NSException *exception)
    {
      failure = [NSString stringWithFormat:
          NSLocalizedString(@"The file manager could not be reached: %@", @""),
          [exception reason]];
    }

  if (!shown)
    {
      if (error != NULL)
        *error = AGInstallerError(AGInstallerErrorReveal, failure);
      return NO;
    }
  return YES;
}

#pragma mark - Private

/* Runs make_services once per install: attempts are counted per install, not
 * retried, so a broken tool cannot turn every Open click into a stall. */
- (void)refreshServicesForApp:(AGApp *)app
{
  NSString *name = [app name];
  if (name != nil)
    {
      @synchronized (self)
        {
          [_servicesRefreshed addObject:name];
        }
    }
  [self runMakeServices];
}

/* The tool itself, run after an install. Its output goes to null because
 * nobody reads it here and a full pipe would stall the tool instead. */
- (void)runMakeServices
{
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:AGMakeServicesPath];
  [task setArguments:@[]];
  [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
  [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
  @try
    {
      [task launch];
      [task waitUntilExit];
    }
  @catch (NSException *exception)
    {
      /* A missing tool must not fail an install that did succeed: the file
       * is in place, and the direct run in launchApp: does not need the
       * services cache at all. */
      (void)exception;
    }
}

@end
