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
