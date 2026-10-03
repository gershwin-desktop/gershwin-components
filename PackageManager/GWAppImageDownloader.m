/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageDownloader - Downloads an AppImage (a direct URL, or the newest
 * GitHub release that actually ships one for this machine) and places it into
 * ~/Applications as a flat, executable <name>.AppImage file (no .app wrapper).
 */

#import "GWAppImageDownloader.h"
#import "GWAppImageAssetPicker.h"
#import "GWCurlMeterReader.h"
#import "GWKDEAppImagePicker.h"
#import "GWPackageManager.h"
#import "GWOSDetector.h"

/*
 * The scale every GWInstallProgressHandler of a run reads, in the 0..1 range
 * the protocol promises: -1 while nothing is measurable (the release lookup,
 * and the first instants of a transfer whose size curl has not learned yet),
 * then the bytes of the transfer itself, then the file moving into place.
 * The transfer gets almost the whole run because it takes almost all of the
 * time; the bar therefore tracks the bytes and reaches the end only when the
 * install really is over.
 */
static const float kGWProgressIndeterminate = -1.0f;
static const float kGWProgressDownloadFirst = 0.05f;
static const float kGWProgressDownloadLast = 0.95f;
static const float kGWProgressSaving = 0.97f;

/* Channels: a repository can publish each channel of an application as a
 * release of its own (tags "stable", "esr", "nightly", ...). The repo of a
 * spec may name one after a "#": "owner/repo#nightly". Only releases (and,
 * within a release, AppImages) whose tag or file name has that word are
 * considered. Without one, those of the other well-known channels are left
 * out as long as there are others. */
static NSString *const GWKnownChannelsPattern =
  @"esr|nightly|beta|devedition|developer[-_ ]?edition|aurora|canary";

/* Splits "owner/repo#Channel" into the repository and the channel (nil when
 * there is none). The channel is limited to letters, digits and ". _ -", and
 * the "." is escaped, so that it is safe to put into a regular expression. */
static NSString *GWSplitChannel(NSString *spec, NSString **channel)
{
  *channel = nil;
  NSRange hash = [spec rangeOfString:@"#"];
  if (hash.location == NSNotFound)
    return spec;

  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
  NSString *raw = [spec substringFromIndex:hash.location + 1];
  NSMutableString *clean = [NSMutableString string];
  for (NSUInteger i = 0; i < [raw length]; i++)
    {
      unichar c = [raw characterAtIndex:i];
      if ([allowed characterIsMember:c])
        [clean appendFormat:@"%C", c];
    }
  if ([clean length] > 0)
    *channel = [clean stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
  return [spec substringToIndex:hash.location];
}

/* Does text contain one of the words (a regular expression) as a whole word,
 * ignoring case ("esr" in "Firefox_ESR-140.3.AppImage", not in "resource")? */
static BOOL GWTextHasWord(NSString *text, NSString *wordPattern)
{
  if ([text length] == 0 || [wordPattern length] == 0)
    return NO;
  NSString *pattern = [NSString stringWithFormat:
                       @"(^|[^a-z0-9])(%@)([^a-z0-9]|$)", wordPattern];
  NSRegularExpression *re =
    [NSRegularExpression regularExpressionWithPattern:pattern
                                              options:NSRegularExpressionCaseInsensitive
                                                error:NULL];
  return re != nil
    && [re firstMatchInString:text options:0 range:NSMakeRange(0, [text length])] != nil;
}

/* Does the tag, or the file name of one of the AppImages, have the word? */
static BOOL GWReleaseHasWord(NSString *tag, NSArray<NSString *> *names,
                             NSString *wordPattern)
{
  if (GWTextHasWord(tag, wordPattern))
    return YES;
  for (NSString *name in names)
    {
      if (GWTextHasWord(name, wordPattern))
        return YES;
    }
  return NO;
}

/* Keeps the names that have the word (match YES) or do not (match NO), unless
 * that would leave none. */
static NSArray<NSString *> *GWNarrowNames(NSArray<NSString *> *names,
                                          NSString *wordPattern, BOOL match)
{
  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  for (NSString *name in names)
    {
      if (GWTextHasWord(name, wordPattern) == match)
        [kept addObject:name];
    }
  return [kept count] > 0 ? kept : names;
}

/* How a download directory could not be read. Three different faults, because
 * the user's next move differs for each: a network problem is worth retrying,
 * a URL that is not a directory is a wrong link in the catalog, and an empty
 * directory is neither. Collapsing them into one "could not read" is what
 * would hide a wrong catalog entry behind a network-sounding message. */
typedef NS_ENUM(NSInteger, GWKDEDirectoryFault) {
  /* The request itself failed, or the body could not be decoded. */
  GWKDEDirectoryUnreachable = 0,
  /* The page was fetched but is not a directory index. */
  GWKDEDirectoryNotAnIndex,
  /* It is an index, and it lists nothing. */
  GWKDEDirectoryEmpty
};

/* The release-resolution half, declared here because the entry point is
 * called from -downloadAppImageFromGitHubRepo: above its definition. The
 * reasoning behind each rule lives in AppGarden/INSTRUCTIONS.md section 8,
 * "Which release, and which file in it".
 *
 * None of this is public API: a caller reaches it only through
 * -downloadAppImageFromGitHubRepo:appName:progress:error: and
 * -downloadAppImageFromKDEListingURL:appName:progress:error:. */
@interface GWAppImageDownloader (ReleaseResolution)

+ (NSString *)resolveGitHubReleaseURLForRepo:(NSString *)repo
                                    appName:(NSString *)appName
                               architecture:(NSString *)arch
                                   progress:(nullable id<GWInstallProgressHandler>)progress
                                      error:(NSError **)error;

+ (NSString *)resolveKDEAppImageURLForListingURL:(NSString *)listingURL
                                        appName:(NSString *)appName
                                   architecture:(NSString *)arch
                                       progress:(nullable id<GWInstallProgressHandler>)progress
                                          error:(NSError **)error;

+ (NSArray<NSString *> *)entryNamesInIndexHTML:(NSString *)html;
+ (NSArray<NSString *> *)entryNamesForDirectoryURL:(NSString *)url
                                           progress:(nullable id<GWInstallProgressHandler>)progress
                                             fault:(GWKDEDirectoryFault *)outFault;
+ (NSError *)KDEDirectoryErrorForFault:(GWKDEDirectoryFault)fault url:(NSString *)url;
+ (NSError *)KDEErrorWithMessage:(NSString *)message;
+ (NSString *)KDEFileSummary:(NSArray<NSString *> *)names;
+ (NSString *)KDEErrorMessageForOutcome:(GWKDEPickOutcome)outcome
                               listing:(NSString *)listing
                          architecture:(NSString *)architecture
                           candidates:(NSArray<NSString *> *)candidates;

/* The tag to use: the newest release that is not a pre-release and does hold
 * an AppImage, failing that the newest that holds one at all. With a channel,
 * the newest release of that channel and no other. */
+ (NSString *)preferredTagForRepo:(NSString *)repo
                           channel:(nullable NSString *)channel
                          progress:(nullable id<GWInstallProgressHandler>)progress;

/* The tag releases/latest redirects to, or nil when it names none (a
 * repository whose only releases are pre-releases, or none at all). The
 * redirect chain is followed to its end, so a renamed repository resolves. */
+ (NSString *)latestStableTagForRepo:(NSString *)repo
                            progress:(nullable id<GWInstallProgressHandler>)progress;

/* The tags of the repository's releases, newest first, from releases.atom. */
+ (NSArray<NSString *> *)releaseTagsForRepo:(NSString *)repo
                                   progress:(nullable id<GWInstallProgressHandler>)progress;

+ (BOOL)fetchURL:(NSString *)url
          toPath:(NSString *)path
        progress:(nullable id<GWInstallProgressHandler>)progress;

+ (NSArray<NSString *> *)assetNamesForRepo:(NSString *)repo
                                      tag:(NSString *)tag
                                  progress:(nullable id<GWInstallProgressHandler>)progress;

+ (BOOL)namesContainAppImage:(NSArray<NSString *> *)names;

@end

@implementation GWAppImageDownloader

+ (NSString *)applicationsDirectory
{
  // The user's own Applications directory, the one GNUstep already reports
  // for NSAllApplicationsDirectory (GNUSTEP_HOME is ~ and the user apps
  // directory is "Applications"), so anything that lands here is picked up
  // by the desktop's application scan without a second scan of its own.
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
}

+ (NSString *)legacyApplicationsDirectory
{
  // Where downloads went before the folder moved: kept only so an install
  // made there can still be found, removed and revealed where it is.
  return [NSHomeDirectory() stringByAppendingPathComponent:
          @"Library/Applications"];
}

+ (NSString *)launcherPathForAppName:(NSString *)appName
{
  // An underscore in the AppImage name becomes a space in the downloaded
  // file name, so "My_App" lands in "My App.AppImage".
  appName = [[appName componentsSeparatedByString:@"_"]
             componentsJoinedByString:@" "];

  // The downloaded AppImage lives directly in the user's Applications
  // directory as a flat, executable file (no .app wrapper).
  NSString *appsDir = [self applicationsDirectory];
  return [appsDir stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@.AppImage", appName]];
}

+ (NSString *)existingLauncherPathForAppName:(NSString *)appName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *path = [self launcherPathForAppName:appName];
  if ([fm fileExistsAtPath:path])
    return path;

  // An install from before the download folder moved is still in the old
  // directory; it answers as installed (and is removed and revealed) from
  // there, instead of looking like nothing was ever downloaded.
  NSString *legacy = [[self legacyApplicationsDirectory]
                      stringByAppendingPathComponent:[path lastPathComponent]];
  if ([fm fileExistsAtPath:legacy])
    return legacy;

  return path;
}

- (BOOL)downloadAppImageFromURL:(NSString *)url
                       appName:(NSString *)appName
                      progress:(nullable id<GWInstallProgressHandler>)progress
                         error:(NSError **)error
{
  if (!url || [url length] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"No AppImage download URL is available for this architecture",
                                 }];
      return NO;
    }

  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"gwpm_%@_%@.AppImage", appName,
                     [[NSUUID UUID] UUIDString]]];
  if (![self _downloadURL:url toPath:tmp progress:progress error:error])
    return NO;

  if (progress)
    [progress installDidProgress:kGWProgressSaving message:@"Saving AppImage..."];

  BOOL ok = [self _downloadAppImageAtPath:tmp appName:appName error:error];
  if (ok && progress)
    [progress installDidProgress:1.0f message:@"Installation complete"];
  return ok;
}

- (BOOL)downloadAppImageFromGitHubRepo:(NSString *)repo
                               appName:(NSString *)appName
                              progress:(nullable id<GWInstallProgressHandler>)progress
                                 error:(NSError **)error
{
  if (!repo || [repo length] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"No GitHub repository is configured for this AppImage",
                                 }];
      return NO;
    }

  NSString *arch = [GWOSDetector currentArchitecture];
  /* No size to show until curl has answered, so the bar runs as a barber
   * pole through the lookup instead of sitting on a made-up percentage. */
  if (progress)
    [progress installDidProgress:kGWProgressIndeterminate
                         message:@"Resolving AppImage from GitHub Releases..."];

  NSError *resolveError = nil;
  /* The catalog's name for the app, not the repository's: a release can hold
   * AppImages of several programs, and the name that tells them apart is the
   * one the catalog lists the app under (FreeCAD's repository is FreeCAD but
   * the catalog calls it FreeCAD2, and Obsidian's is obsidian-releases). */
  NSString *url = [self.class resolveGitHubReleaseURLForRepo:repo
                                                   appName:appName
                                                architecture:arch
                                                    progress:progress
                                                       error:&resolveError];
  if (!url)
    {
      if (error) *error = resolveError;
      return NO;
    }

  return [self downloadAppImageFromURL:url appName:appName progress:progress error:error];
}

- (BOOL)downloadAppImageFromKDEListingURL:(NSString *)listingURL
                                 appName:(NSString *)appName
                                progress:(nullable id<GWInstallProgressHandler>)progress
                                   error:(NSError **)error
{
  if (!listingURL || [listingURL length] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"No download directory is configured for this AppImage",
                                 }];
      return NO;
    }

  NSString *arch = [GWOSDetector currentArchitecture];
  if (progress)
    [progress installDidProgress:kGWProgressIndeterminate
                         message:@"Resolving AppImage from the download directory..."];

  NSError *resolveError = nil;
  NSString *url = [self.class resolveKDEAppImageURLForListingURL:listingURL
                                                        appName:appName
                                                   architecture:arch
                                                       progress:progress
                                                          error:&resolveError];
  if (!url)
    {
      if (error) *error = resolveError;
      return NO;
    }

  return [self downloadAppImageFromURL:url appName:appName progress:progress error:error];
}

#pragma mark - Private helpers

- (BOOL)_downloadURL:(NSString *)url
              toPath:(NSString *)dest
            progress:(nullable id<GWInstallProgressHandler>)progress
               error:(NSError **)error
{
  /* Nothing is measurable until curl has read a size, and the meter keeps
   * saying so until its first percent arrives. */
  if (progress)
    [progress installDidProgress:kGWProgressIndeterminate
                         message:@"Downloading AppImage..."];

  GWCurlMeterReader *meter =
      [[GWCurlMeterReader alloc] initWithProgress:progress
                                          message:@"Downloading AppImage..."
                                            first:kGWProgressDownloadFirst
                                              last:kGWProgressDownloadLast];

  // We deliberately use curl over NSURLSession: libdispatch/GCD is unreliable
  // in this runtime, and a plain NSTask keeps the download synchronous and
  // easy to drive from a background thread.
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  // -# is curl's progress meter as machine readable as it gets: a percent at
  // the end of every update, where the default meter writes columns instead.
  [t setArguments:@[@"-fL", @"--progress-bar", @"--retry", @"2",
                    @"--retry-delay", @"1",
                    @"-o", dest, url]];
  // With -o the body goes to the file, so stdout carries nothing; stderr
  // carries the meter and the failure text, and it has to be read *while*
  // curl writes it: nobody reading the pipe not only keeps the bar frozen,
  // it blocks curl for good once 64 KB of meter has piled up in it.
  [t setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
  NSPipe *errPipe = [NSPipe pipe];
  [t setStandardError:errPipe];

  @try
    {
      [t launch];

      /* Reading to end of file is also the wait for the transfer: the write
       * end of the pipe closes when curl exits, and every update is parsed
       * as it lands, on this thread, in the order it was written. */
      NSFileHandle *err = [errPipe fileHandleForReading];
      for (;;)
        {
          NSData *chunk = [err availableData];
          if ([chunk length] == 0)
            break;
          [meter ingestData:chunk];
        }
      [meter finish];
      [t waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWAppImageDownloader -> download failed: %@", e);
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"Could not download %@", url],
                                 }];
      return NO;
    }

  if ([t terminationStatus] != 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"Download failed for %@", url],
                                 }];
      return NO;
    }

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:dest])
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Download produced no file",
                                 }];
      return NO;
    }
  return YES;
}

- (BOOL)_downloadAppImageAtPath:(NSString *)src
                         appName:(NSString *)appName
                           error:(NSError **)error
{
  // An underscore in the AppImage name becomes a space in the downloaded
  // file name (e.g. "My_App" -> "My App.AppImage").
  appName = [[appName componentsSeparatedByString:@"_"]
             componentsJoinedByString:@" "];

  NSFileManager *fm = [NSFileManager defaultManager];

  // The AppImage is placed directly into ~/Applications as a flat,
  // executable file - no .app wrapper, no launcher script.
  NSString *dest = [GWAppImageDownloader launcherPathForAppName:appName];

  // Remove any previous download of the same app.
  [fm removeItemAtPath:dest error:nil];

  // Make sure the target directory exists.
  NSString *destDir = [dest stringByDeletingLastPathComponent];
  NSError *dirError = nil;
  if (![fm createDirectoryAtPath:destDir
         withIntermediateDirectories:YES
                          attributes:nil
                               error:&dirError])
    {
      if (error) *error = dirError;
      return NO;
    }

  // Move the downloaded AppImage into place.
  if (![fm moveItemAtPath:src toPath:dest error:error])
    return NO;
  [fm setAttributes:@{NSFilePosixPermissions:@0755}
       ofItemAtPath:dest
              error:nil];

  return YES;
}

+ (NSString *)resolveGitHubReleaseURLForRepo:(NSString *)repo
                                    appName:(NSString *)appName
                               architecture:(NSString *)arch
                                   progress:(nullable id<GWInstallProgressHandler>)progress
                                      error:(NSError **)error
{
  return [self resolveGitHubReleaseURLForRepo:repo
                                     appName:appName
                                  architecture:arch
                                      progress:progress
                                         error:error
                                startingAtTag:nil];
}

+ (NSString *)resolveGitHubReleaseURLForRepo:(NSString *)repo
                                    appName:(NSString *)appName
                               architecture:(NSString *)arch
                                   progress:(nullable id<GWInstallProgressHandler>)progress
                                      error:(NSError **)error
                               startingAtTag:(NSString *)startTag
{
  NSString *channel = nil;
  repo = GWSplitChannel(repo, &channel);

  // The web site instead of api.github.com: the API allows 60 anonymous
  // requests per hour per address, and once a desktop had used them up every
  // Get in AppGarden and every Software Update check failed with 403 for the
  // rest of the hour. github.com itself answers releases/latest with a
  // redirect to the tag page, and releases/expanded_assets/<tag> with the
  // asset list as plain links; neither is rate limited that way.
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"gwpm_gh_%@.html",
                     [[NSUUID UUID] UUIDString]]];

  // Which release to look at: the newest one that is not a pre-release and
  // does hold an AppImage, or the newest that holds one at all. Deciding
  // that here, once, is why the walk below is only a safety net rather than
  // the normal path.
  NSString *tag = startTag;
  if (tag == nil)
    {
      tag = [self preferredTagForRepo:repo channel:channel progress:progress];
      if (tag == nil)
        {
          if (error)
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                         code:GWPackageManagerErrorCommandFailed
                                     userInfo:@{
                                       NSLocalizedDescriptionKey: channel
                                         ? [NSString stringWithFormat:
                                             @"No release of %@ has an AppImage for the channel \"%@\"",
                                             repo, [channel stringByReplacingOccurrencesOfString:@"\\." withString:@"."]]
                                         : [NSString stringWithFormat:
                                             @"No release of %@ has an AppImage", repo],
                                       }];
          return nil;
        }
    }

  // A tag with a slash in it has to be percent-encoded to sit in a path,
  // which is how janhq/jan's "checkpoint/code-ui-..." tag is spelled.
  NSString *encodedTag = [tag stringByAddingPercentEncodingWithAllowedCharacters:
                          [NSCharacterSet URLPathAllowedCharacterSet]];
  NSString *assetsPage = [NSString stringWithFormat:
                          @"https://github.com/%@/releases/expanded_assets/%@",
                          repo, encodedTag];

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fsSL", @"-o", tmp, assetsPage]];
  // The lookup runs silent (-s), so nothing lands on stderr but the failure
  // itself - and that is exactly what a caller needs: a rate limit or a 403
  // from GitHub is the reason the error below gives, and this pipe is the
  // only way it leaves the framework.
  NSPipe *assetsErr = [NSPipe pipe];
  [t setStandardError:assetsErr];
  @try
    {
      [t launch];
      [GWCurlMeterReader forwardStderrOfPipe:assetsErr toProgress:progress];
      [t waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWAppImageDownloader -> GitHub request failed: %@", e);
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"Could not reach GitHub for %@", repo],
                                   }];
      return nil;
    }

  NSString *html = [NSString stringWithContentsOfFile:tmp
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
  if ([t terminationStatus] != 0 || html == nil)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"GitHub release assets could not be read for %@", repo],
                                 }];
      return nil;
    }

  // Every asset appears as a link to /<owner>/<repo>/releases/download/<tag>/<file>;
  // the entries carry the two keys the selection below always read from the
  // API's JSON, so that code stays as it was.
  NSMutableArray *assets = [NSMutableArray array];
  NSRegularExpression *link = [NSRegularExpression regularExpressionWithPattern:
      @"href=\"(/[^\"]+/releases/download/[^\"]+)\"" options:0 error:NULL];
  for (NSTextCheckingResult *match in [link matchesInString:html options:0
                                                         range:NSMakeRange(0, [html length])])
    {
      NSString *path = [[html substringWithRange:[match rangeAtIndex:1]]
                        stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
      [assets addObject:@{
        @"name": [path lastPathComponent],
        @"browser_download_url": [@"https://github.com" stringByAppendingString:path],
      }];
    }

  NSArray<NSString *> *names = [assets valueForKey:@"name"];

  // A release with no AppImage in it, however many other files it carries:
  // Obsidian 1.13.8 is a mobile-only release holding a single .apk. An assets
  // page listing an .apk is not an empty one, so the test is for an AppImage
  // and not for any asset at all. preferredTagForRepo: should already have
  // walked past such a release, so reaching here means it could not.
  if (![self namesContainAppImage:names])
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"No release of %@ has an AppImage", repo],
                                   }];
      return nil;
    }

  if ([assets count] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"No release assets found for %@", repo],
                                 }];
      return nil;
    }

  // The catalog's own rules, so that "the AppImage of this release" means
  // here what it means on appimage.github.io.
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSArray<NSString *> *candidates = nil;
  // Several channels in one release: the files of the channel, or, without
  // one, not those of the other channels.
  names = channel != nil
    ? GWNarrowNames(names, channel, YES)
    : GWNarrowNames(names, GWKnownChannelsPattern, NO);
  NSString *chosen = [GWAppImageAssetPicker pickAssetFromNames:names
                                                      appName:appName
                                                      outcome:&outcome
                                                   candidates:&candidates];

  if (chosen == nil)
    {
      if (error)
        {
          NSString *reason;
          if (outcome == GWAppImagePickAmbiguous)
            // Say which files, so the user can fetch one by hand if they
            // want to: guessing here would hand them the wrong program.
            reason = [NSString stringWithFormat:
                      @"The newest release of %@ has several AppImages and none of "
                      @"them is clearly the right one for this machine: %@",
                      repo, [candidates componentsJoinedByString:@", "]];
          else
            reason = [NSString stringWithFormat:
                      @"No release of %@ has an AppImage for this machine", repo];
          *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                       code:GWPackageManagerErrorCommandFailed
                                   userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
      return nil;
    }

  for (NSDictionary *asset in assets)
    {
      if ([[asset objectForKey:@"name"] isEqualToString:chosen])
        {
          NSString *downloadURL = [asset objectForKey:@"browser_download_url"];
          if ([downloadURL length] > 0)
            return downloadURL;
        }
    }

  if (error)
    *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                 code:GWPackageManagerErrorCommandFailed
                             userInfo:@{
                               NSLocalizedDescriptionKey:
                                 @"GitHub asset is missing a download URL",
                               }];
  return nil;
}

#pragma mark - Walking back through releases

/* Fetch a URL into a file, quietly. A failure is the caller's to report. */
+ (BOOL)fetchURL:(NSString *)url
          toPath:(NSString *)path
        progress:(nullable id<GWInstallProgressHandler>)progress
{
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fsSL", @"-o", path, url]];
  NSPipe *err = [NSPipe pipe];
  [t setStandardError:err];
  @try
    {
      [t launch];
      [GWCurlMeterReader forwardStderrOfPipe:err toProgress:progress];
      [t waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWAppImageDownloader -> request failed: %@", e);
      return NO;
    }
  return [t terminationStatus] == 0;
}

/* The asset names of one release, in the order the forge lists them. */
+ (NSArray<NSString *> *)assetNamesForRepo:(NSString *)repo
                                      tag:(NSString *)tag
                                  progress:(nullable id<GWInstallProgressHandler>)progress
{
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"gwpm_assets_%@.html",
                      [[NSUUID UUID] UUIDString]]];
  NSString *encoded = [tag stringByAddingPercentEncodingWithAllowedCharacters:
                       [NSCharacterSet URLPathAllowedCharacterSet]];
  NSString *page = [NSString stringWithFormat:
                    @"https://github.com/%@/releases/expanded_assets/%@",
                    repo, encoded];
  if (![self fetchURL:page toPath:path progress:progress])
    {
      [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
      return nil;
    }
  NSString *html = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  if (html == nil)
    return nil;

  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSRegularExpression *link = [NSRegularExpression regularExpressionWithPattern:
      @"href=\"(/[^\"]+/releases/download/[^\"]+)\"" options:0 error:NULL];
  for (NSTextCheckingResult *match in [link matchesInString:html options:0
                                                         range:NSMakeRange(0, [html length])])
    {
      NSString *assetPath = [html substringWithRange:[match rangeAtIndex:1]];
      [names addObject:[assetPath lastPathComponent]];
    }
  return names;
}

/* The tags of a repository's releases, newest first, read from the Atom
 * feed github.com serves for them. This is the same walk the catalog does
 * through the API, done with the web endpoint so a desktop that has already
 * spent its anonymous API allowance can still install anything. */
+ (NSArray<NSString *> *)releaseTagsForRepo:(NSString *)repo
                                   progress:(nullable id<GWInstallProgressHandler>)progress
{
  NSString *feed = [NSString stringWithFormat:
                    @"https://github.com/%@/releases.atom", repo];
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"gwpm_tags_%@.atom",
                      [[NSUUID UUID] UUIDString]]];
  if (![self fetchURL:feed toPath:path progress:progress])
    {
      [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
      return nil;
    }

  NSString *xml = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  if (xml == nil)
    return nil;

  /* The tag is the last path component of the entry's own link, never its
   * title: Obsidian titles v1.13.7 "1.13.7" with no v, and AppFlowy titles
   * 0.14.5 "v0.14.5" with one. */
  NSRegularExpression *entry =
    [NSRegularExpression regularExpressionWithPattern:
      @"<entry>(.*?)</entry>" options:NSRegularExpressionDotMatchesLineSeparators
                                             error:NULL];
  NSRegularExpression *tag =
    [NSRegularExpression regularExpressionWithPattern:
      @"href=\"[^\"]*/releases/tag/([^\"]+)\"" options:0 error:NULL];

  NSMutableArray<NSString *> *tags = [NSMutableArray array];
  for (NSTextCheckingResult *e in [entry matchesInString:xml options:0
                                                  range:NSMakeRange(0, [xml length])])
    {
      NSString *body = [xml substringWithRange:[e rangeAtIndex:1]];
      NSTextCheckingResult *m = [tag firstMatchInString:body options:0
                                                  range:NSMakeRange(0, [body length])];
      if (m != nil)
        {
          NSString *value = [[body substringWithRange:[m rangeAtIndex:1]]
                             stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
          if (![tags containsObject:value])
            [tags addObject:value];
        }
    }
  return tags;
}

/* The tag releases/latest redirects to, which is by definition the newest
 * release GitHub does not consider a pre-release, or nil when it names none
 * (a repository whose only releases are pre-releases, or none at all).
 *
 * The redirect has to be followed rather than read once: a renamed
 * repository answers 301 first, and the first Location of a renamed one
 * still ends in /releases/latest, so the tag is only in the last header. */
+ (NSString *)latestStableTagForRepo:(NSString *)repo
                            progress:(nullable id<GWInstallProgressHandler>)progress
{
  NSString *headers = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"gwpm_latest_%@.headers",
                         [[NSUUID UUID] UUIDString]]];
  NSString *url = [NSString stringWithFormat:
                   @"https://github.com/%@/releases/latest", repo];
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fsSIL", @"-o", headers, url]];
  NSPipe *err = [NSPipe pipe];
  [t setStandardError:err];
  BOOL ok = NO;
  @try
    {
      [t launch];
      [GWCurlMeterReader forwardStderrOfPipe:err toProgress:progress];
      [t waitUntilExit];
      ok = ([t terminationStatus] == 0);
    }
  @catch (NSException *e)
    {
      ok = NO;
    }
  if (!ok)
    {
      [[NSFileManager defaultManager] removeItemAtPath:headers error:NULL];
      return nil;
    }

  NSString *text = [NSString stringWithContentsOfFile:headers
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:headers error:NULL];
  NSString *tag = nil;
  for (NSString *line in [text componentsSeparatedByString:@"\n"])
    {
      NSRange colon = [line rangeOfString:@":"];
      if (colon.location == NSNotFound)
        continue;
      if (![[[line substringToIndex:colon.location] lowercaseString]
             isEqualToString:@"location"])
        continue;
      NSString *where = [[line substringFromIndex:colon.location + 1]
                         stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSRange tagRange = [where rangeOfString:@"/releases/tag/"];
      if (tagRange.location != NSNotFound)
        tag = [where substringFromIndex:NSMaxRange(tagRange)];
      /* Keep the last one: with -L the chain is written out in order and the
       * tag is on the final hop, not the first. */
    }
  return tag;
}

/* Does this release carry a file that IS an AppImage? The end-anchored,
 * case-insensitive test the picker itself starts from, so "there is nothing
 * here to install" and "there is something but we cannot choose it" stay
 * two different answers. */
+ (BOOL)namesContainAppImage:(NSArray<NSString *> *)names
{
  for (NSString *name in names)
    {
      if ([[name lowercaseString] hasSuffix:@".appimage"])
        return YES;
    }
  return NO;
}

/* How far back to look for a release that actually has an AppImage. The
 * Atom feed holds ten entries, and a project that has stopped shipping
 * AppImages in its last six releases is not going to be helped by a seventh
 * request. */
static const NSUInteger kGWMaxReleasesToWalk = 6;

/* The newest release that is not a pre-release and does contain an AppImage;
 * failing that, the newest one that does, pre-release or not. This is the
 * catalog's own first rule, and each half of it is load-bearing on real
 * projects: Obsidian's newest release is a mobile-only .apk, so the rule has
 * to look past a release that merely exists, and qTox publishes only
 * pre-releases, so it has to accept one when nothing else is on offer. */
+ (NSString *)preferredTagForRepo:(NSString *)repo
                           channel:(nullable NSString *)channel
                          progress:(nullable id<GWInstallProgressHandler>)progress
{
  /* releases/latest is the web site's own answer to "the newest real
   * release", so following its redirect gives the newest non-prerelease
   * without a second request to find out which entries are pre-releases
   * (the Atom feed does not say, and the releases page would have to be
   * fetched and parsed to find out). A channel is not the latest release
   * of anything, so it goes through the feed alone. */
  NSString *stable = channel == nil
    ? [self latestStableTagForRepo:repo progress:progress] : nil;
  NSArray<NSString *> *tags = [self releaseTagsForRepo:repo progress:progress];
  NSUInteger count = MIN([tags count], kGWMaxReleasesToWalk);

  NSMutableArray<NSString *> *order = [NSMutableArray array];
  if (stable != nil)
    [order addObject:stable];
  for (NSUInteger i = 0; i < count; i++)
    {
      if (![[tags objectAtIndex:i] isEqualToString:stable])
        [order addObject:[tags objectAtIndex:i]];
    }

  /* Releases of the other well-known channels only count when the
   * repository has no others: a plain "owner/repo" must not install the
   * nightly just because it is the newest. */
  for (int pass = 0; pass < (channel == nil ? 2 : 1); pass++)
    {
      BOOL skipOtherChannels = (channel == nil && pass == 0);
      for (NSString *tag in order)
        {
          NSArray<NSString *> *names = [self assetNamesForRepo:repo
                                                           tag:tag
                                                      progress:progress];
          if (![self namesContainAppImage:names])
            continue;
          if (channel != nil)
            {
              if (!GWReleaseHasWord(tag, names, channel))
                continue;
            }
          else if (skipOtherChannels
                   && GWReleaseHasWord(tag, names, GWKnownChannelsPattern))
            continue;
          return tag;
        }
    }
  return nil;
}

#pragma mark - Walking a download.kde.org directory

/* How many version directories to look at before giving up. A Get that costs
   an unbounded number of requests is a Get that can hang, and the newest
   directories are the only ones anyone installs: labplot and rkward each
   ship exactly one, and of the rest only krita has more than two. */
static const NSUInteger kGWMaxKDEVersionDirsToWalk = 4;

/* The entry names of one autoindex page: the relative hrefs, with the
   server's own chrome and the trailing slash removed. nil when the page is
   not a directory index at all, which is what an ordinary web page is: the
   KDE application page for digiKam (apps.kde.org/digikam) has links but no
   "Parent Directory" row, and reading its links as a file list would
   resolve a download page to a bug-report link. */
+ (NSArray<NSString *> *)entryNamesInIndexHTML:(NSString *)html
{
  if (html == nil || [html length] == 0)
    return nil;

  /* The marker every autoindex page carries, and the one thing that tells
     this page apart from a page that merely links to files. */
  if ([html rangeOfString:@"Parent Directory"
                  options:NSCaseInsensitiveSearch].location == NSNotFound)
    return nil;

  static NSRegularExpression *href = nil;
  if (href == nil)
    href = [NSRegularExpression regularExpressionWithPattern:@"href=\"([^\"]+)\""
                                                    options:NSCaseInsensitiveSearch
                                                      error:NULL];

  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  [href enumerateMatchesInString:html
                         options:0
                           range:NSMakeRange(0, [html length])
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f,
                                   BOOL *stop) {
    NSString *value = [html substringWithRange:[m rangeAtIndex:1]];
    /* Query strings are the column sort links, a leading slash is either an
       absolute path or the page's own chrome, and "://" is a link out to
       another site (the KDE footer). None of them is a file in this
       directory. */
    if ([value length] == 0 || [value hasPrefix:@"?"] ||
        [value hasPrefix:@"/"] || [value rangeOfString:@"://"].location != NSNotFound)
      return;
    if ([value hasPrefix:@"#"] || [value hasPrefix:@"mailto:"])
      return;
    while ([value hasSuffix:@"/"])
      value = [value substringToIndex:[value length] - 1];
    if ([value length] == 0 || [value isEqualToString:@".."] ||
        [value isEqualToString:@"."])
      return;
    if (![seen containsObject:value])
      {
        [seen addObject:value];
        [names addObject:value];
      }
  }];
  return names;
}

/* Join a directory URL and the entry inside it. */
static NSString *GWKDEURL(NSString *base, NSString *entry)
{
  if ([base hasSuffix:@"/"])
    return [base stringByAppendingString:entry];
  return [base stringByAppendingFormat:@"/%@", entry];
}

/* Fetch one directory's index into memory. On failure, entries is nil and
   fault says which of the three it was. */
+ (NSArray<NSString *> *)entryNamesForDirectoryURL:(NSString *)url
                                           progress:(nullable id<GWInstallProgressHandler>)progress
                                             fault:(GWKDEDirectoryFault *)outFault
{
  if (outFault != NULL)
    *outFault = GWKDEDirectoryUnreachable;

  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"gwpm_kde_%@.html",
                      [[NSUUID UUID] UUIDString]]];
  if (![self fetchURL:url toPath:path progress:progress])
    {
      [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
      return nil;
    }
  NSString *html = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

  NSArray<NSString *> *names = [self entryNamesInIndexHTML:html];
  if (names == nil)
    {
      if (outFault != NULL)
        *outFault = GWKDEDirectoryNotAnIndex;
      return nil;
    }
  if ([names count] == 0 && outFault != NULL)
    *outFault = GWKDEDirectoryEmpty;
  return names;
}

/* The message for a directory that could not be used at all. */
+ (NSError *)KDEDirectoryErrorForFault:(GWKDEDirectoryFault)fault
                                  url:(NSString *)url
{
  switch (fault)
    {
    case GWKDEDirectoryNotAnIndex:
      return [self KDEErrorWithMessage:
                [NSString stringWithFormat:
                  @"%@ is not a download directory, so no AppImage can be chosen from it",
                  url]];
    case GWKDEDirectoryEmpty:
      return [self KDEErrorWithMessage:
                [NSString stringWithFormat:
                  @"The download directory %@ is empty", url]];
    case GWKDEDirectoryUnreachable:
      break;
    }
  return [self KDEErrorWithMessage:
            [NSString stringWithFormat:
              @"Could not reach the download directory %@", url]];
}

+ (NSError *)KDEErrorWithMessage:(NSString *)message
{
  return [NSError errorWithDomain:GWPackageManagerErrorDomain
                             code:GWPackageManagerErrorCommandFailed
                         userInfo:@{ NSLocalizedDescriptionKey: message }];
}

/* One sentence naming what a version directory holds, for the error when
   nothing in it can be used. */
+ (NSString *)KDEFileSummary:(NSArray<NSString *> *)names
{
  if ([names count] == 0)
    return @"it is empty";
  if ([names count] <= 3)
    return [[NSArray arrayWithObjects:
             [names objectAtIndex:0],
             ([names count] > 1 ? [names objectAtIndex:1] : nil),
             ([names count] > 2 ? [names objectAtIndex:2] : nil), nil]
            componentsJoinedByString:@", "];
  return [NSString stringWithFormat:@"%@ and %lu more",
            [names objectAtIndex:0], (unsigned long)([names count] - 1)];
}

+ (NSString *)resolveKDEAppImageURLForListingURL:(NSString *)listingURL
                                        appName:(NSString *)appName
                                   architecture:(NSString *)arch
                                       progress:(nullable id<GWInstallProgressHandler>)progress
                                          error:(NSError **)error
{
  if (error != NULL)
    *error = nil;

  GWKDEDirectoryFault fault = GWKDEDirectoryUnreachable;
  NSArray<NSString *> *entries =
    [self entryNamesForDirectoryURL:listingURL progress:progress fault:&fault];
  if (entries == nil)
    {
      if (error != NULL)
        *error = [self KDEDirectoryErrorForFault:fault url:listingURL];
      return nil;
    }

  /* The flat shape is tried first, and on the application directory's own
     entries, whether or not it also has version directories. labplot is the
     measured case for it (its AppImage sits in the application directory with
     no version level at all), and trying it first means a directory that has
     both shapes, whose newest version holds a build for another CPU, still
     finds the file sitting in its own directory instead of refusing. */
  BOOL hasAppImageHere = NO;
  for (NSString *name in entries)
    {
      if ([[name lowercaseString] hasSuffix:@".appimage"])
        {
          hasAppImageHere = YES;
          break;
        }
    }

  NSArray<NSString *> *versions =
    [GWKDEAppImagePicker versionDirectoriesFromEntryNames:entries];
  NSUInteger walk = MIN([versions count], kGWMaxKDEVersionDirsToWalk);

  if (hasAppImageHere && walk == 0)
    {
      GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
      NSArray<NSString *> *candidates = nil;
      NSString *file = [GWKDEAppImagePicker pickFileFromNames:entries
                                                      appName:appName
                                                  architecture:arch
                                                      outcome:&outcome
                                                   candidates:&candidates];
      if (file != nil)
        return GWKDEURL(listingURL, file);
      if (error != NULL)
        *error = [self KDEErrorWithMessage:
                   [self KDEErrorMessageForOutcome:outcome
                                          listing:listingURL
                                      architecture:arch
                                       candidates:candidates]];
      return nil;
    }

  /* Whether any walked directory could be read at all. Without it, a
     directory tree that was entirely unreachable would end in "no version
     has an AppImage for this machine", blaming the machine for a network
     fault. */
  BOOL readAny = NO;

  /* Walk the version directories newest first. A directory that holds no
     AppImage at all (kstars 3.8.4.1 is a source tarball, haruna 1.8.1 holds
     no Linux build) means this version cannot serve an install, and the next
     older one may: that is the same walk-back the GitHub resolver does. */
  for (NSUInteger i = 0; i < walk; i++)
    {
      NSString *version = [versions objectAtIndex:i];
      NSString *dirURL = GWKDEURL(listingURL, version);
      NSArray<NSString *> *files =
        [self entryNamesForDirectoryURL:dirURL progress:progress fault:NULL];
      if (files == nil)
        continue;   /* that directory is gone or unreadable; try the next */
      readAny = YES;

      GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
      NSArray<NSString *> *candidates = nil;
      NSString *file = [GWKDEAppImagePicker pickFileFromNames:files
                                                      appName:appName
                                                  architecture:arch
                                                      outcome:&outcome
                                                   candidates:&candidates];
      if (file != nil)
        return GWKDEURL(dirURL, file);

      /* An architecture or an ambiguity is a refusal, not a reason to look
         further back: the newest release is the one the user asked for, and
         quietly installing an older build of the same application instead is
         a surprise, not a service. */
      if (outcome != GWKDEPickNoAppImage)
        {
          if (error != NULL)
            *error = [self KDEErrorWithMessage:
                       [self KDEErrorMessageForOutcome:outcome
                                              listing:dirURL
                                          architecture:arch
                                           candidates:candidates]];
          return nil;
        }
    }

  if (error != NULL)
    {
      if (!readAny)
        *error = [self KDEErrorWithMessage:
                   [NSString stringWithFormat:
                     @"None of the %lu version directories under %@ could be read",
                     (unsigned long)walk, listingURL]];
      else
        *error = [self KDEErrorWithMessage:
                   [NSString stringWithFormat:
                     @"No version of the application at %@ has an AppImage for this machine",
                     listingURL]];
    }
  return nil;
}

+ (NSString *)KDEErrorMessageForOutcome:(GWKDEPickOutcome)outcome
                               listing:(NSString *)listing
                           architecture:(NSString *)arch
                            candidates:(NSArray<NSString *> *)candidates
{
  NSString *dir = [listing lastPathComponent];
  switch (outcome)
    {
    case GWKDEPickNoAppImageForArchitecture:
      return [NSString stringWithFormat:
                @"%@ has no AppImage for this machine (%@); it holds %@",
                dir, arch, [self KDEFileSummary:candidates]];
    case GWKDEPickAmbiguous:
      {
        /* A nil list would print "(null)", which reads as a filename. It
         * cannot happen today, but the message is what the user sees when
         * something else goes wrong, so it is worth being definite. */
        NSString *names = ([candidates count] > 0)
          ? [[candidates sortedArrayUsingSelector:@selector(compare:)]
             componentsJoinedByString:@", "]
          : @"none";
        return [NSString stringWithFormat:
                  @"%@ holds several AppImages and none of them is clearly the right one: %@",
                  dir, names];
      }
    case GWKDEPickNoAppImage:
      return [NSString stringWithFormat:@"%@ has no AppImage", dir];
    case GWKDEPickChosen:
      /* Not reachable: a chosen file is returned as the result, not as an
       * error. The assertion is here so that adding a caller that ignores
       * the result finds out here rather than reading a sentence that says
       * the opposite of the outcome. */
      NSAssert(outcome != GWKDEPickChosen,
               @"a chosen file is not an error message");
      return [NSString stringWithFormat:@"%@: the AppImage was chosen", dir];
    }
  return [NSString stringWithFormat:@"%@ has no AppImage", dir];
}

@end
