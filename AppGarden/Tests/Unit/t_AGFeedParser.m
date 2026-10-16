/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGError.h"
#import "AGFeedParser.h"
#import "AGCatalog.h"
#import "AGApp.h"

/* The tool runs with the Tests/Unit directory as its working directory
 * (the test runner changes into the suite before running each tool). */
static NSString *fixturePath = @"../../Fixtures/feed-sample.json";

static NSUInteger indexOfDisplayName(NSArray *apps, NSString *displayName)
{
  NSUInteger index;
  for (index = 0; index < [apps count]; index++)
    {
      if ([[[apps objectAtIndex: index] displayName] isEqualToString: displayName])
        return index;
    }
  return NSNotFound;
}

static AGCatalog *parseFixture(NSError **error)
{
  NSData *data = [NSData dataWithContentsOfFile: fixturePath];
  return [AGFeedParser catalogFromData: data
                             fetchDate: [NSDate dateWithTimeIntervalSince1970: 1700000000]
                                 error: error];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSError *error = nil;

  /* --- the real feed shape parses into a full catalog --- */
  {
    NSDate *fetched = [NSDate dateWithTimeIntervalSince1970: 1700000000];
    NSData *data = [NSData dataWithContentsOfFile: fixturePath];
    PASS(data != nil, "fixture %s is readable", [fixturePath UTF8String]);

    AGCatalog *catalog = [AGFeedParser catalogFromData: data
                                             fetchDate: fetched
                                                 error: &error];
    PASS(catalog != nil, "fixture parses without error: %s",
         (catalog != nil) ? "ok" : [[error localizedDescription] UTF8String]);
    /* The fixture documents 16 items, so 16 apps means zero skipped. */
    PASS([catalog apps] != nil && [[catalog apps] count] == 16,
         "all 16 fixture items parsed and none were skipped (got %lu)",
         (unsigned long)[[catalog apps] count]);
    PASS([catalog appNamed: @"4KWALL"] != nil, "appNamed: finds 4KWALL");
    PASS_EQUAL([catalog fetchDate], fetched,
               "the fetch date passes through to the catalog");
    PASS(indexOfDisplayName([catalog apps], @"lux") != NSNotFound,
         "every fixture item is listed");
  }

  /* --- derivation rules per item --- */
  {
    NSError *parseError = nil;
    AGCatalog *catalog = parseFixture(&parseError);
    PASS(catalog != nil, "fixture parses for the derivation checks");

    PASS_EQUAL([[catalog appNamed: @"Apache_NetBeans"] displayName],
               @"Apache NetBeans",
               "displayName replaces underscores with spaces");

    AGApp *box = [catalog appNamed: @"86Box"];
    PASS([box descriptionText] == nil, "86Box has no descriptionText");
    PASS([box summary] == nil, "86Box has no summary without a description");
    PASS([box license] == nil, "86Box has no license");

    AGApp *addaps = [catalog appNamed: @"Addaps"];
    PASS(addaps != nil, "Addaps is listed");
    PASS([[addaps links] count] == 0, "a null links array becomes an empty array");
    PASS([addaps iconURL] == nil, "Addaps has no icon to draw");
    PASS([addaps downloadPageURL] == nil, "Addaps has nothing to download");
    PASS([addaps githubRepo] == nil, "Addaps has no GitHub repository");
    PASS([[addaps authors] count] == 0, "a null authors array becomes an empty array");
    PASS([addaps screenshotURL] != nil,
         "the screenshot still resolves while links are null");

    AGApp *ddcal = [catalog appNamed: @"DDCal"];
    PASS(ddcal != nil, "DDCal is still listed with no categories");
    NSArray *noCategories = [NSArray array];
    PASS_EQUAL([ddcal categories], noCategories,
               "a null category entry is dropped");

    PASS_EQUAL([[[catalog appNamed: @"BlackMirror"] downloadPageURL] absoluteString],
               @"https://github.com/sorentycho/blackmirror/releases",
               "an Install link acts as the download page");

    AGApp *qown = [catalog appNamed: @"QOwnNotes"];
    PASS([qown iconURL] == nil, "an svg icon yields no icon URL");
    PASS([[[qown downloadPageURL] absoluteString] hasSuffix: @".mirrorlist"],
         "the openSUSE mirror list is the download page");
    PASS([qown githubRepo] == nil, "QOwnNotes has no GitHub repository");

    AGApp *wall = [catalog appNamed: @"4KWALL"];
    PASS_EQUAL([[wall iconURL] absoluteString],
               @"https://appimage.github.io/database/4KWALL/icons/512x512/com.warlordsoftwares.wallpaper-app-4kwall.png",
               "the icon URL is absolute on the catalog host");
    PASS_EQUAL([[wall screenshotURL] absoluteString],
               @"https://appimage.github.io/database/4KWALL/screenshot.png",
               "the screenshot URL is absolute on the catalog host");
    PASS_EQUAL([wall githubRepo], @"rishabh3354/4KWALL",
               "githubRepo comes from the GitHub link value");
    PASS_EQUAL([[wall githubURL] absoluteString],
               @"https://github.com/rishabh3354/4KWALL",
               "githubURL is derived from githubRepo");
    PASS_EQUAL([[wall catalogPageURL] absoluteString],
               @"https://appimage.github.io/4KWALL/",
               "the catalog page URL points at the item's site page");
    PASS_EQUAL([wall summary],
               @"Browse, download, and auto-change 4K wallpapers",
               "a short description survives as the summary verbatim");

    PASS([[catalog appNamed: @"OVideo"] selfContained],
         "OVideo reports itself self-contained");
    PASS([[catalog appNamed: @"Addaps"] selfContainedPresent] == NO,
         "a missing self_contained key leaves the presence flag clear");
    PASS_EQUAL([[catalog appNamed: @"APK_Editor_Studio"] glibcRequired], @"2.30",
               "glibcRequired is kept");

    PASS([[catalog appNamed: @"Alpine_Client"] authors] != nil
         && [[[catalog appNamed: @"Alpine_Client"] authors] count] == 0,
         "a null authors array becomes an empty array on Alpine_Client");

    NSString *artifactSummary = [[catalog appNamed: @"Artifact"] summary];
    PASS(artifactSummary != nil && [artifactSummary length] <= 90,
         "the Artifact summary fits 90 characters (got %lu)",
         (unsigned long)[artifactSummary length]);
    PASS([artifactSummary hasSuffix: @"…"],
         "the over-long summary ends with the ellipsis");
  }

  /* --- apps are sorted case-insensitively by displayName --- */
  {
    NSError *parseError = nil;
    AGCatalog *catalog = parseFixture(&parseError);
    NSArray *apps = [catalog apps];
    NSUInteger luxIndex = indexOfDisplayName(apps, @"lux");
    PASS(luxIndex != NSNotFound && luxIndex < [apps count] - 1,
         "a lowercase name does not sink to the last place (lux at %lu of %lu)",
         (unsigned long)luxIndex, (unsigned long)[apps count]);
    NSUInteger netbeansIndex = indexOfDisplayName(apps, @"Apache NetBeans");
    NSUInteger apkIndex = indexOfDisplayName(apps, @"APK Editor Studio");
    PASS(netbeansIndex != NSNotFound && apkIndex != NSNotFound
         && netbeansIndex < apkIndex,
         "Apache NetBeans sorts before APK Editor Studio case-insensitively");
  }

  /* --- a Download link alone still yields a GitHub repository --- */
  {
    NSString *json = @"{\"items\": [{\"name\": \"Synth\", \"links\": [{\"type\": \"Download\", \"url\": \"https://github.com/a/b/releases\"}]}]}";
    NSError *synthError = nil;
    AGCatalog *catalog = [AGFeedParser catalogFromData: [json dataUsingEncoding: NSUTF8StringEncoding]
                                             fetchDate: [NSDate date]
                                                 error: &synthError];
    PASS(catalog != nil, "the synthetic item parses");
    PASS_EQUAL([[catalog appNamed: @"Synth"] githubRepo], @"a/b",
               "a releases Download link yields the repo when no GitHub link exists");
  }

  /* --- HTML in a description is reduced to its text --- */
  {
    NSString *json = @"{\"items\": [{\"name\": \"Marked\", \"description\": \"<p>Client for <b>X</b> &amp; Y.</p><p>Second line</p>\"}]}";
    NSError *htmlError = nil;
    AGCatalog *catalog = [AGFeedParser catalogFromData: [json dataUsingEncoding: NSUTF8StringEncoding]
                                             fetchDate: [NSDate date]
                                                 error: &htmlError];
    AGApp *marked = [catalog appNamed: @"Marked"];
    PASS_EQUAL([marked descriptionText], @"Client for X & Y.\nSecond line",
               "tags are dropped, paragraphs become lines and entities decode");
    PASS_EQUAL([marked summary], @"Client for X & Y.",
               "the summary is taken from the cleaned text");
  }

  /* --- fail hard on documents that are not a usable feed --- */
  {
    NSError *emptyError = nil;
    AGCatalog *catalog = [AGFeedParser catalogFromData: [NSData data]
                                             fetchDate: [NSDate date]
                                                 error: &emptyError];
    PASS(catalog == nil, "empty data yields no catalog");
    PASS([emptyError code] == AGErrorNotJSON && [[emptyError domain] isEqualToString: AGErrorDomain],
         "empty data is a not-JSON error in AGErrorDomain (code %ld)",
         (long)[emptyError code]);
    PASS([[emptyError localizedDescription] length] > 0,
         "the error carries a human-readable description: %s",
         [[emptyError localizedDescription] UTF8String]);
  }
  {
    NSError *arrayError = nil;
    NSData *data = [@"[1, 2]" dataUsingEncoding: NSUTF8StringEncoding];
    AGCatalog *catalog = [AGFeedParser catalogFromData: data fetchDate: [NSDate date] error: &arrayError];
    PASS(catalog == nil && [arrayError code] == AGErrorTopLevelNotDictionary,
         "a top-level array is rejected as not a JSON object");
  }
  {
    NSError *missingError = nil;
    NSData *data = [@"{\"version\": 1}" dataUsingEncoding: NSUTF8StringEncoding];
    AGCatalog *catalog = [AGFeedParser catalogFromData: data fetchDate: [NSDate date] error: &missingError];
    PASS(catalog == nil && [missingError code] == AGErrorItemsMissing,
         "a missing items key is rejected");
  }
  {
    NSError *shapeError = nil;
    NSData *data = [@"{\"items\": 5}" dataUsingEncoding: NSUTF8StringEncoding];
    AGCatalog *catalog = [AGFeedParser catalogFromData: data fetchDate: [NSDate date] error: &shapeError];
    PASS(catalog == nil && [shapeError code] == AGErrorItemsNotArray,
         "a non-array items key is rejected");
    PASS([[shapeError localizedDescription] length] > 0,
         "the items error is human-readable: %s",
         [[shapeError localizedDescription] UTF8String]);
  }

  /* --- malformed items are skipped, not fatal --- */
  {
    NSError *junkError = nil;
    NSData *data = [@"{\"items\": [1, {\"name\": \"x\"}, {\"noname\": 1}]}"
                        dataUsingEncoding: NSUTF8StringEncoding];
    AGCatalog *catalog = [AGFeedParser catalogFromData: data fetchDate: [NSDate date] error: &junkError];
    PASS(catalog != nil && junkError == nil,
         "junk items do not fail the whole feed");
    PASS([[catalog apps] count] == 1,
         "one app from one good item, two skipped (got %lu)",
         (unsigned long)[[catalog apps] count]);
    PASS_EQUAL([[catalog appNamed: @"x"] displayName], @"x",
               "the one good item survived");
  }

  [arp release];
  return 0;
}
