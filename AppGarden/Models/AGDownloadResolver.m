/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGDownloadResolver.h"
#import "AGApp.h"

#include <sys/utsname.h>

static BOOL AGHasSuffixIgnoringCase(NSString *string, NSString *suffix)
{
  NSRange suffixRange = [string rangeOfString:suffix
                                      options:NSCaseInsensitiveSearch | NSAnchoredSearch | NSBackwardsSearch];
  return suffixRange.location != NSNotFound;
}

/* Whether a download link is a download.kde.org application directory rather
 * than a file or an ordinary web page.
 *
 * All three conditions are needed. The host, because the resolver to use is
 * the one that reads a directory index. The trailing slash, because that is
 * what makes it a directory: the file links in the catalog end in a name
 * (".AppImage") and the page links do not end in a slash. And a path with at
 * least two components after the host, because /stable/ on its own is the
 * list of applications, not one application. The series directory in the
 * middle (stable, nightly, attic) is not checked by name, so a new series
 * keeps working. */
static BOOL AGIsKDEFileListingURL(NSString *URLString)
{
  if (URLString == nil || ![URLString hasSuffix:@"/"])
    return NO;

  NSRange schemeRange = [URLString rangeOfString:@"://"];
  if (schemeRange.location == NSNotFound)
    return NO;

  NSString *rest = [URLString substringFromIndex:
                    NSMaxRange(schemeRange)];
  NSRange slash = [rest rangeOfString:@"/"];
  if (slash.location == NSNotFound)
    return NO;

  NSString *host = [rest substringToIndex:slash.location];
  if ([host caseInsensitiveCompare:@"download.kde.org"] != NSOrderedSame)
    return NO;

  NSString *path = [rest substringFromIndex:NSMaxRange(slash)];
  NSMutableArray<NSString *> *components = [NSMutableArray array];
  for (NSString *part in [path componentsSeparatedByString:@"/"])
    if ([part length] > 0)
      [components addObject:part];

  return [components count] >= 2;
}

@implementation AGDownloadResolver

+ (NSString *)currentArchitecture
{
  struct utsname info;
  if (uname(&info) != 0)
    return @"unknown";

  NSString *machine = [NSString stringWithCString:info.machine
                                         encoding:NSUTF8StringEncoding];
  return (machine != nil) ? machine : @"unknown";
}

+ (AGDownloadKind)kindForApp:(AGApp *)app payload:(id *)payload
{
  return [self kindForApp:app architecture:[self currentArchitecture] payload:payload];
}

+ (AGDownloadKind)kindForApp:(AGApp *)app
               architecture:(NSString *)architecture
                    payload:(id *)payload
{
  if (payload != NULL)
    *payload = nil;

  if (app == nil)
    return AGDownloadKindNone;

  NSString *repo = [app githubRepo];
  if ([repo length] > 0)
    {
      if (payload != NULL)
        *payload = repo;
      return AGDownloadKindGitHubLatestRelease;
    }

  NSURL *page = [app downloadPageURL];
  if (page == nil)
    return AGDownloadKindNone;

  NSString *URLString = [page absoluteString];

  // A download.kde.org application link names a directory, not a file:
  // https://download.kde.org/stable/digikam/ lists version directories and
  // the newest of those lists the builds. The framework reads the index and
  // picks the file, the same way it reads a release and picks the asset.
  if (AGIsKDEFileListingURL(URLString))
    {
      if (payload != NULL)
        *payload = page;
      return AGDownloadKindKDEFileListing;
    }

  if (AGHasSuffixIgnoringCase(URLString, @".AppImage"))
    {
      if (payload != NULL)
        *payload = page;
      return AGDownloadKindDirectURL;
    }

  if (AGHasSuffixIgnoringCase(URLString, @".AppImage.mirrorlist"))
    {
      // The mirror list names the single build it points at. When that build
      // is for another CPU there is nothing to fetch from here, so the user
      // gets the page instead of a file that cannot run.
      NSString *fileName = [page lastPathComponent];
      BOOL namesOtherArchitecture =
        [fileName rangeOfString:@"x86_64" options:NSCaseInsensitiveSearch].location != NSNotFound;
      if (namesOtherArchitecture && ![architecture isEqualToString:@"x86_64"])
        {
          if (payload != NULL)
            *payload = page;
          return AGDownloadKindWebPageOnly;
        }

      NSString *stripped = [URLString substringToIndex:
                              [URLString length] - [@".mirrorlist" length]];
      NSURL *fileURL = [NSURL URLWithString:stripped];
      if (fileURL == nil)
        {
          if (payload != NULL)
            *payload = page;
          return AGDownloadKindWebPageOnly;
        }
      if (payload != NULL)
        *payload = fileURL;
      return AGDownloadKindDirectURL;
    }

  if (payload != NULL)
    *payload = page;
  return AGDownloadKindWebPageOnly;
}

@end
