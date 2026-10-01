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

// Channels: a repository can publish each channel of an application as a
// release of its own (tags "stable", "esr", "nightly", ...).  The repo of a
// spec may name one after a "#": "owner/repo#nightly".  Only releases (and,
// within a release, AppImages) whose tag or file name has that word are
// considered.  Without one, those of the other well-known channels are left out.
static NSString *const GWKnownChannelsPattern =
  @"esr|nightly|beta|devedition|developer[-_ ]?edition|aurora|canary";

// A channel is limited to letters, digits and ". _ -"; only "." is special in a pattern.
static NSString *GWEscapedWord(NSString *word)
{
  return [word stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
}

static NSError *GWDownloaderError(NSString *message)
{
  return [NSError errorWithDomain:GWPackageManagerErrorDomain
                             code:GWPackageManagerErrorCommandFailed
                         userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// Does text contain one of the words (a regular expression) as a whole word,
// ignoring case ("esr" in "Firefox_ESR-140.3.AppImage", not in "resource")?
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

static BOOL GWAssetIsAppImage(NSDictionary *asset)
{
  NSString *name = [[asset objectForKey:@"name"] lowercaseString];
  if (![name isKindOfClass:[NSString class]]) return NO;
  return [name hasSuffix:@".appimage"] || [name containsString:@".appimage."];
}

static NSArray<NSDictionary *> *GWAppImageAssets(NSDictionary *release)
{
  NSMutableArray<NSDictionary *> *appImages = [NSMutableArray array];
  NSArray *assets = release[@"assets"];
  if (![assets isKindOfClass:[NSArray class]]) return appImages;
  for (NSDictionary *asset in assets)
    {
      if ([asset isKindOfClass:[NSDictionary class]] && GWAssetIsAppImage(asset))
        [appImages addObject:asset];
    }
  return appImages;
}

// Does the release's tag, or the file name of one of its AppImages, have the word?
static BOOL GWReleaseHasWord(NSDictionary *release, NSString *wordPattern)
{
  if (GWTextHasWord(release[@"tag_name"], wordPattern)) return YES;
  for (NSDictionary *asset in GWAppImageAssets(release))
    {
      if (GWTextHasWord([asset objectForKey:@"name"], wordPattern)) return YES;
    }
  return NO;
}

// Keeps the dictionaries whose "name" has the word (match YES) or does not
// (match NO), unless that would leave none.
static NSArray<NSDictionary *> *GWNarrowAssets(NSArray<NSDictionary *> *assets,
                                               NSString *wordPattern, BOOL match)
{
  NSMutableArray<NSDictionary *> *kept = [NSMutableArray array];
  for (NSDictionary *asset in assets)
    {
      if (GWTextHasWord([asset objectForKey:@"name"], wordPattern) == match)
        [kept addObject:asset];
    }
  return [kept count] > 0 ? kept : assets;
}

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

+ (id)_fetchGitHubJSON:(NSString *)api
                    repo:(NSString *)repo
                   error:(NSError **)error
{
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"gwpm_gh_%@.json",
                     [[NSUUID UUID] UUIDString]]];

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"curl"];
  [t setArguments:@[@"-fL",
                    @"-H", @"Accept: application/vnd.github+json",
                    @"-o", tmp, api]];
  @try
    {
      [t launch];
      [t waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWAppImageDownloader -> GitHub API request failed: %@", e);
      if (error)
        *error = GWDownloaderError(
          [NSString stringWithFormat:@"Could not reach GitHub for %@", repo]);
      return nil;
    }

  if ([t terminationStatus] != 0)
    {
      if (error)
        *error = GWDownloaderError(
          [NSString stringWithFormat:@"GitHub release lookup failed for %@", repo]);
      return nil;
    }

  NSData *json = [NSData dataWithContentsOfFile:tmp];
  [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
  if (!json)
    {
      if (error)
        *error = GWDownloaderError(@"GitHub returned an empty response");
      return nil;
    }

  NSError *parseError = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:json
                                              options:0
                                                error:&parseError];
  if (!parsed)
    {
      if (error) *error = parseError;
      return nil;
    }
  return parsed;
}

// The release to take an AppImage from.  Without a channel, the latest release
// of the repository, unless that is one of another channel (a tag or AppImage
// named esr, nightly, beta, ...) while the repository has others; with one, the
// newest release of that channel (a release before a pre-release).
+ (NSDictionary *)_releaseForRepo:(NSString *)repo
                          channel:(nullable NSString *)channel
                            error:(NSError **)error
{
  if ([channel length] == 0)
    {
      NSString *api = [NSString stringWithFormat:
                       @"https://api.github.com/repos/%@/releases/latest", repo];
      id latest = [self _fetchGitHubJSON:api repo:repo error:error];
      if (!latest) return nil;
      if (![latest isKindOfClass:[NSDictionary class]])
        {
          if (error)
            *error = GWDownloaderError(@"GitHub returned an unexpected response");
          return nil;
        }
      if (!GWReleaseHasWord(latest, GWKnownChannelsPattern))
        return latest;
      // Falls through: look for the newest release without a channel
    }

  NSString *api = [NSString stringWithFormat:
                   @"https://api.github.com/repos/%@/releases?per_page=100", repo];
  id list = [self _fetchGitHubJSON:api repo:repo error:error];
  if (!list) return nil;
  if (![list isKindOfClass:[NSArray class]])
    {
      if (error)
        *error = GWDownloaderError(@"GitHub returned an unexpected response");
      return nil;
    }

  NSString *word = [channel length] > 0
    ? GWEscapedWord(channel) : nil;
  NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
  NSMutableArray<NSDictionary *> *others = [NSMutableArray array];
  for (NSDictionary *release in (NSArray *)list)
    {
      if (![release isKindOfClass:[NSDictionary class]]) continue;
      if ([[release objectForKey:@"draft"] boolValue]) continue;
      if ([GWAppImageAssets(release) count] == 0) continue;
      if (word)
        {
          if (GWReleaseHasWord(release, word)) [candidates addObject:release];
        }
      else if (GWReleaseHasWord(release, GWKnownChannelsPattern))
        [others addObject:release];
      else
        [candidates addObject:release];
    }
  // With a channel and no release of it there is nothing to guess at.  Without
  // one, if every release is of some channel, take the newest of those.
  if ([candidates count] == 0 && !word)
    [candidates addObjectsFromArray:others];
  if ([candidates count] == 0)
    {
      if (error)
        *error = GWDownloaderError(word
          ? [NSString stringWithFormat:
              @"No release of %@ with an AppImage for the channel \"%@\"",
              repo, channel]
          : [NSString stringWithFormat:
              @"No release with an AppImage found for %@", repo]);
      return nil;
    }
  for (NSDictionary *release in candidates)
    {
      if (![[release objectForKey:@"prerelease"] boolValue]) return release;
    }
  return candidates[0];
}

+ (NSString *)resolveGitHubReleaseURLForRepo:(NSString *)repo
                               architecture:(NSString *)arch
                                      error:(NSError **)error
{
  // "owner/repo" or "owner/repo#Channel"
  NSString *channel = nil;
  NSRange hash = [repo rangeOfString:@"#"];
  if (hash.location != NSNotFound)
    {
      NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
      NSString *raw = [repo substringFromIndex:hash.location + 1];
      NSMutableString *clean = [NSMutableString string];
      for (NSUInteger i = 0; i < [raw length]; i++)
        {
          unichar c = [raw characterAtIndex:i];
          if ([allowed characterIsMember:c])
            [clean appendFormat:@"%C", c];
        }
      channel = [clean length] > 0 ? clean : nil;
      repo = [repo substringToIndex:hash.location];
    }

  NSDictionary *release = [self _releaseForRepo:repo channel:channel error:error];
  if (!release) return nil;
  NSLog(@"GWAppImageDownloader -> %@%@%@: using release %@", repo,
        channel ? @" channel " : @"", channel ? channel : @"",
        [release objectForKey:@"tag_name"]);

  NSArray<NSDictionary *> *appImages = GWAppImageAssets(release);
  if ([appImages count] == 0)
    {
      if (error)
        *error = GWDownloaderError(
          [NSString stringWithFormat:@"No release assets found for %@", repo]);
      return nil;
    }

  // Within the release: the AppImages of the channel, or, without one, not those
  // of the other channels (several channels in one release)
  if ([channel length] > 0)
    appImages = GWNarrowAssets(appImages,
                               GWEscapedWord(channel), YES);
  else
    appImages = GWNarrowAssets(appImages, GWKnownChannelsPattern, NO);

  // Heuristic: prefer one whose name mentions the current architecture
  // (aarch64/arm64 or x86_64/amd64), falling back to the first AppImage if no
  // arch-specific match exists.
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
        *error = GWDownloaderError(
          [NSString stringWithFormat:@"No AppImage asset for architecture %@ in %@",
            arch, repo]);
      return nil;
    }

  NSString *downloadURL = [matched objectForKey:@"browser_download_url"];
  if (!downloadURL || [downloadURL length] == 0)
    {
      if (error)
        *error = GWDownloaderError(@"GitHub asset is missing a download URL");
      return nil;
    }
  NSLog(@"GWAppImageDownloader -> %@: AppImage %@", repo,
        [matched objectForKey:@"name"]);
  return downloadURL;
}

@end
