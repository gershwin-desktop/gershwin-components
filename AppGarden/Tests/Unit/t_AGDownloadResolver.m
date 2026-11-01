/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGFeedParser.h"
#import "AGCatalog.h"
#import "AGApp.h"
#import "AGDownloadResolver.h"

static NSString *fixturePath = @"../../Fixtures/feed-sample.json";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  NSData *data = [NSData dataWithContentsOfFile: fixturePath];
  NSError *error = nil;
  AGCatalog *catalog = [AGFeedParser catalogFromData: data
                                           fetchDate: [NSDate date]
                                               error: &error];
  PASS(catalog != nil, "fixture parses: %s",
       (catalog != nil) ? "ok" : [[error localizedDescription] UTF8String]);

  /* --- a GitHub link wins over everything else --- */
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"4KWALL"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindGitHubLatestRelease,
         "4KWALL resolves to its latest GitHub release");
    PASS_EQUAL(payload, @"rishabh3354/4KWALL",
               "the payload is the github repo");
  }
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"BlackMirror"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindGitHubLatestRelease,
         "an Install-only item still resolves through GitHub");
    PASS_EQUAL(payload, @"sorentycho/blackmirror",
               "the payload is the github repo");
  }
  {
    /* The signature from the brief: no architecture in, so the resolver
     * uses the machine it runs on - the GitHub path ignores it either way. */
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"4KWALL"]
                                                 payload: &payload];
    PASS(kind == AGDownloadKindGitHubLatestRelease,
         "kindForApp:payload: reaches the same GitHub decision");
    PASS_EQUAL(payload, @"rishabh3354/4KWALL",
               "the payload is the github repo");
  }

  /* --- the openSUSE mirror list depends on the CPU --- */
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"QOwnNotes"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindDirectURL,
         "QOwnNotes on x86_64 downloads the AppImage file directly");
    PASS_EQUAL([(NSURL *)payload absoluteString],
               @"https://download.opensuse.org/repositories/home:/pbek:/QOwnNotes/AppImage/QOwnNotes-latest-x86_64.AppImage",
               "the .mirrorlist suffix is stripped from the payload");
  }
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"QOwnNotes"]
                                            architecture: @"aarch64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindWebPageOnly,
         "the x86_64-only mirror list is a web page on aarch64");
    PASS_EQUAL([(NSURL *)payload absoluteString],
               @"https://download.opensuse.org/repositories/home:/pbek:/QOwnNotes/AppImage/QOwnNotes-latest-x86_64.AppImage.mirrorlist",
               "the payload is the unchanged download page");
  }

  /* --- a download.kde.org application directory is a file we can fetch --- */
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"digiKam"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindKDEFileListing,
         "a download.kde.org application directory resolves to a listing, "
         "not to a page that can only be opened");
    PASS_EQUAL([(NSURL *)payload absoluteString],
               @"https://download.kde.org/stable/digikam/",
               "the payload is the directory to read");
  }

  /* --- no file can be fetched from here --- */
  {
    id payload = nil;
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"lux"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindWebPageOnly,
         "a foreign download page can only be opened, not fetched");
    PASS_EQUAL([(NSURL *)payload absoluteString],
               @"https://bitbucket.org/kfj/pv/downloads",
               "the payload is the download page");
  }

  /* --- nothing at all --- */
  {
    id payload = @"untouched";
    AGDownloadKind kind = [AGDownloadResolver kindForApp: [catalog appNamed: @"Addaps"]
                                            architecture: @"x86_64"
                                                 payload: &payload];
    PASS(kind == AGDownloadKindNone, "an item with no links resolves to None");
    PASS(payload == nil, "the payload is cleared when nothing can be fetched");
  }

  [arp release];
  return 0;
}
