/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCSoftwareInstaller.h"
#import <AppKit/AppKit.h>
#import <PackageManager/GWPackageManager.h>
#import <PackageManager/GWOSDetector.h>
#import <PackageManager/ODProgressWindow.h>

/* Carries one install to its worker thread, and progress back to the window */
@interface SCInstallJob : NSObject <GWInstallProgressHandler>
@property (nonatomic, copy) NSArray *packages;
@property (nonatomic, copy) NSString *what;
@property (nonatomic, strong) ODProgressWindow *window;
@property (nonatomic, copy) void (^completion)(BOOL installed);
@property (nonatomic, strong) NSError *error;
@property (nonatomic) BOOL succeeded;
@end

static NSMutableSet *runningJobs;

@implementation SCInstallJob

- (void) installDidProgress: (float)progress message: (NSString *)message
{
  [self performSelectorOnMainThread: @selector(showProgress:)
                         withObject: @{@"progress": @(progress),
                                       @"message": message ? message : @""}
                      waitUntilDone: NO];
}

- (void) showProgress: (NSDictionary *)p
{
  [_window updateProgress: [[p objectForKey: @"progress"] floatValue]
                  message: [p objectForKey: @"message"]];
}

- (void) run: (id)unused
{
  @autoreleasepool
    {
      NSError *error = nil;

      /* Blocks for as long as the package manager runs, hence the thread */
      _succeeded = [[GWPackageManager sharedManager] installPackages: _packages
                                                      localFilePaths: @[]
                                                            progress: self
                                                               error: &error];
      _error = error;
      [self performSelectorOnMainThread: @selector(finish:) withObject: nil
                          waitUntilDone: NO];
    }
}

- (void) finish: (id)unused
{
  [_window orderOut: nil];
  if (!_succeeded)
    {
      NSAlert *alert = [NSAlert new];

      [alert setMessageText: [NSString stringWithFormat:
        @"%@ could not be installed.", [_what capitalizedString]]];
      [alert setInformativeText: _error ? [_error localizedDescription]
             : @"The package manager reported a failure."];
      [alert runModal];
    }
  [runningJobs removeObject: self];
  _completion(_succeeded);
}

@end

@implementation SCSoftwareInstaller

+ (NSArray *) packagesForLanguages: (NSArray *)codes
                     withTesseract: (BOOL)withTesseract
                            family: (NSString *)family
{
  NSMutableArray *packages = [NSMutableArray array];

  if ([family isEqualToString: @"debian"])
    {
      if (withTesseract)
        {
          [packages addObject: @"tesseract-ocr"];
        }
      for (NSString *code in codes)
        {
          /* Debian writes chi_sim as chi-sim in package names */
          [packages addObject: [@"tesseract-ocr-" stringByAppendingString:
            [code stringByReplacingOccurrencesOfString: @"_" withString: @"-"]]];
        }
    }
  else if ([family isEqualToString: @"arch"])
    {
      /* Unlike elsewhere, tesseract comes without any language on Arch */
      if (withTesseract)
        {
          [packages addObject: @"tesseract"];
          if (![codes containsObject: @"eng"])
            {
              [packages addObject: @"tesseract-data-eng"];
            }
        }
      for (NSString *code in codes)
        {
          [packages addObject: [@"tesseract-data-" stringByAppendingString: code]];
        }
    }
  else if ([family isEqualToString: @"freebsd"])
    {
      if (withTesseract)
        {
          [packages addObject: @"tesseract"];
        }
      /* FreeBSD ships all languages in one package, which tesseract pulls in */
      if ([codes count] > 0 && !withTesseract)
        {
          [packages addObject: @"tesseract-data"];
        }
    }
  else if ([family isEqualToString: @"openbsd"])
    {
      if (withTesseract)
        {
          [packages addObject: @"tesseract"];
        }
      for (NSString *code in codes)
        {
          [packages addObject: [@"tesseract-" stringByAppendingString: code]];
        }
    }
  else
    {
      return nil;
    }
  return packages;
}

+ (NSArray *) packagesForLanguages: (NSArray *)codes
                     withTesseract: (BOOL)withTesseract
{
  return [self packagesForLanguages: codes withTesseract: withTesseract
                             family: [GWOSDetector packageManagerFamily]];
}

+ (NSArray *) scannerSupportPackagesForFamily: (NSString *)family
{
  if ([family isEqualToString: @"debian"])
    {
      return @[@"libsane1", @"sane-airscan"];
    }
  if ([family isEqualToString: @"arch"])
    {
      return @[@"sane", @"sane-airscan"];
    }
  if ([family isEqualToString: @"freebsd"])
    {
      return @[@"sane-backends", @"sane-airscan"];
    }
  /* sane-airscan is a port on OpenBSD, but its package name is not confirmed */
  if ([family isEqualToString: @"openbsd"])
    {
      return @[@"sane-backends"];
    }
  return nil;
}

+ (NSArray *) scannerSupportPackages
{
  return [self scannerSupportPackagesForFamily: [GWOSDetector packageManagerFamily]];
}

+ (void) offerLanguages: (NSArray *)codes
          withTesseract: (BOOL)withTesseract
                   what: (NSString *)what
             completion: (void (^)(BOOL installed))completion
{
  [self offerPackages: [self packagesForLanguages: codes withTesseract: withTesseract]
                 what: what
               reason: @"Scanned PDFs become searchable once the text on them "
                       @"can be recognized."
           completion: completion];
}

+ (void) offerPackages: (NSArray *)packages
                  what: (NSString *)what
                reason: (NSString *)reason
            completion: (void (^)(BOOL installed))completion
{
  NSAlert *alert = [NSAlert new];
  SCInstallJob *job;

  if ([packages count] == 0)
    {
      [alert setMessageText: [NSString stringWithFormat:
        @"%@ is not installed.", [what capitalizedString]]];
      [alert setInformativeText: [NSString stringWithFormat:
        @"%@ Scanner does not know the package names on this system; install "
        @"%@ with the system's package manager.", reason, what]];
      [alert runModal];
      completion(NO);
      return;
    }

  [alert setMessageText: [NSString stringWithFormat: @"Install %@?", what]];
  [alert setInformativeText: [NSString stringWithFormat:
    @"%@ This needs these packages from the Internet:\n\n%@", reason,
    [packages componentsJoinedByString: @"\n"]]];
  [alert addButtonWithTitle: @"Install"];
  [alert addButtonWithTitle: @"Not Now"];
  if ([alert runModal] != NSAlertFirstButtonReturn)
    {
      completion(NO);
      return;
    }

  job = [SCInstallJob new];
  [job setPackages: packages];
  [job setWhat: what];
  [job setCompletion: completion];
  [job setWindow: [[ODProgressWindow alloc]
                    initWithTitle: [NSString stringWithFormat: @"Installing %@",
                                             what]
                          message: [NSString stringWithFormat:
                                     @"Installing %@...", what]
                         packages: packages]];
  [[job window] showWindow: nil];
  if (runningJobs == nil)
    {
      runningJobs = [NSMutableSet set];
    }
  [runningJobs addObject: job];
  [NSThread detachNewThreadSelector: @selector(run:) toTarget: job withObject: nil];
}

@end
