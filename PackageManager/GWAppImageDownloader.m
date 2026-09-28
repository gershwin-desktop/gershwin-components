/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageDownloader - Downloads an AppImage (direct URL or latest GitHub
 * release asset) and places it into ~/Library/Applications as a native
 * .app bundle wrapping the AppImage plus a launcher script.
 */

#import "GWAppImageDownloader.h"
#import "GWPackageManager.h"
#import "GWOSDetector.h"

@implementation GWAppImageDownloader

+ (NSString *)launcherPathForAppName:(NSString *)appName
{
  // An underscore in the AppImage name becomes a space in the downloaded
  // file name, so "My_App" lands in "My App.AppImage".
  appName = [[appName componentsSeparatedByString:@"_"]
             componentsJoinedByString:@" "];

  // The downloaded AppImage lives directly in the user's home Applications
  // directory as a flat, executable file (no .app wrapper).
  NSString *home = NSHomeDirectory();
  NSString *appsDir = [home stringByAppendingPathComponent:@"Library/Applications"];
  return [appsDir stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@.AppImage", appName]];
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
    [progress installDidProgress:0.6f message:@"Saving AppImage..."];

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
  if (progress)
    [progress installDidProgress:0.05f
                         message:@"Resolving AppImage from GitHub Releases..."];

  NSError *resolveError = nil;
  NSString *url = [self.class resolveGitHubReleaseURLForRepo:repo
                                               architecture:arch
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
  if (progress)
    [progress installDidProgress:0.1f message:@"Downloading AppImage..."];

  // We deliberately use curl over NSURLSession: libdispatch/GCD is unreliable
  // in this runtime, and a plain NSTask keeps the download synchronous and
  // easy to drive from a background thread.
  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fL", @"--retry", @"2", @"--retry-delay", @"1",
                    @"-o", dest, url]];
  NSPipe *ioPipe = [NSPipe pipe];
  [t setStandardOutput:ioPipe];
  [t setStandardError:ioPipe];

  @try
    {
      [t launch];
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

  // The AppImage is placed directly into ~/Library/Applications as a flat,
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
                               architecture:(NSString *)arch
                                      error:(NSError **)error
{
  // The web site instead of api.github.com: the API allows 60 anonymous
  // requests per hour per address, and once a desktop had used them up every
  // Get in AppGarden and every Software Update check failed with 403 for the
  // rest of the hour. github.com itself answers releases/latest with a
  // redirect to the tag page, and releases/expanded_assets/<tag> with the
  // asset list as plain links; neither is rate limited that way.
  NSString *latest = [NSString stringWithFormat:
                      @"https://github.com/%@/releases/latest", repo];
  NSString *headers = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"gwpm_gh_%@.headers",
                         [[NSUUID UUID] UUIDString]]];
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"gwpm_gh_%@.html",
                     [[NSUUID UUID] UUIDString]]];

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fsSI", @"-o", headers, latest]];
  @try
    {
      [t launch];
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

  NSString *headerText = [NSString stringWithContentsOfFile:headers
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:headers error:NULL];
  NSString *tagURL = nil;
  for (NSString *line in [headerText componentsSeparatedByString:@"\n"])
    {
      NSRange colon = [line rangeOfString:@":"];
      if (colon.location == NSNotFound)
        continue;
      NSString *field = [[line substringToIndex:colon.location] lowercaseString];
      if ([field isEqualToString:@"location"])
        tagURL = [[line substringFromIndex:colon.location + 1]
                  stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
  // A repository without a release answers releases/latest with the
  // releases page itself, not a redirect to a tag.
  NSRange tagRange = [tagURL rangeOfString:@"/releases/tag/"];
  if ([t terminationStatus] != 0 || tagURL == nil || tagRange.location == NSNotFound)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"GitHub release lookup failed for %@", repo],
                                 }];
      return nil;
    }
  NSString *tag = [tagURL substringFromIndex:NSMaxRange(tagRange)];
  NSString *assetsPage = [NSString stringWithFormat:
                          @"https://github.com/%@/releases/expanded_assets/%@",
                          repo, tag];

  t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fsSL", @"-o", tmp, assetsPage]];
  @try
    {
      [t launch];
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

  // Heuristic: collect .AppImage assets, then prefer one whose name mentions
  // the current architecture (aarch64/arm64 or x86_64/amd64), falling back to
  // the first AppImage if no arch-specific match exists.
  NSMutableArray<NSDictionary *> *appImages = [NSMutableArray array];
  for (NSDictionary *asset in assets)
    {
      NSString *name = [[asset objectForKey:@"name"] lowercaseString];
      if (name == nil) continue;
      // Only the file itself: the checksum and zsync files next to it end in
      // .AppImage.<something> and used to be picked up as candidates.
      if ([name hasSuffix:@".appimage"])
        [appImages addObject:asset];
    }

  NSString *primary = ([arch isEqualToString:@"aarch64"]) ? @"aarch64" : @"x86_64";
  NSString *secondary = ([arch isEqualToString:@"aarch64"]) ? @"arm64" : @"amd64";

  NSDictionary *matched = nil;
  for (NSDictionary *asset in appImages)
    {
      NSString *name = [[asset objectForKey:@"name"] lowercaseString];
      if ([name containsString:primary] || [name containsString:secondary])
        {
          matched = asset;
          break;
        }
    }
  if (!matched && [appImages count] > 0)
    matched = appImages[0];

  if (!matched)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     [NSString stringWithFormat:
                                       @"No AppImage asset for architecture %@ in %@",
                                       arch, repo],
                                 }];
      return nil;
    }

  NSString *downloadURL = [matched objectForKey:@"browser_download_url"];
  if (!downloadURL || [downloadURL length] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"GitHub asset is missing a download URL",
                                 }];
      return nil;
    }
  return downloadURL;
}

@end
