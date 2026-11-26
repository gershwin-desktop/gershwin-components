/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWKDEAppImagePicker.h"
#import "GWAppImageAssetPicker.h"

/*
 * Every rule below was measured against download.kde.org on 2026-09-28. The
 * comment on each says which real directory it exists for; a rule that never
 * changed an answer is not here.
 *
 * As in GWAppImageAssetPicker, the preference rules are no-ops unless they
 * keep SOME but not ALL of the candidates, so no rule can empty the field.
 * The architecture rule is the one deliberate exception, and it is the whole
 * point of this class: see pickFileFromNames.
 */

/* The digits at the start of one component of a version, so "5" and "5.27.11"
 * order as numbers. A component with no leading digits counts as 0. In
 * practice no such component reaches here: +isVersionDirectoryName: only
 * admits digits and dots, and deliberately leaves out a suffixed name such as
 * "24.08.1-rc1", which no directory on the site is named today. Admitting one
 * would need the trailing letters ordered too, which is a decision about
 * whether a release candidate counts as a release. */
static NSUInteger AGKDEVersionComponent(NSString *component)
{
  NSUInteger value = 0;
  NSUInteger seen = 0;
  for (NSUInteger i = 0; i < [component length]; i++)
    {
      unichar c = [component characterAtIndex:i];
      if (c < '0' || c > '9')
        break;
      value = value * 10 + (NSUInteger)(c - '0');
      seen++;
    }
  return seen > 0 ? value : 0;
}

/* The components of a version directory name, without the leading "v". */
static NSArray<NSString *> *AGKDEVersionComponents(NSString *name)
{
  NSString *s = name;
  if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"])
    s = [s substringFromIndex:1];
  NSArray<NSString *> *parts = [s componentsSeparatedByString:@"."];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *p in parts)
    if ([p length] > 0)
      [out addObject:p];
  return out;
}

/* The architecture spelled in a file name, or nil when it names none. Only
 * the spellings that were measured on download.kde.org are listed:
 * crow-translate and krita write x86_64, digiKam writes x86-64, and no
 * directory measured ships an arm AppImage at all. */
static BOOL AGKDENamesArchitecture(NSString *lowerName, NSString *architecture)
{
  NSString *want = [architecture lowercaseString];
  NSString *pattern = nil;

  if ([want isEqualToString:@"x86_64"] || [want isEqualToString:@"amd64"])
    pattern = @"(^|[^a-z0-9])(x86[-_]64|amd64|x64|64-?bit)([^a-z0-9]|$)";
  else if ([want isEqualToString:@"aarch64"] || [want isEqualToString:@"arm64"])
    pattern = @"(^|[^a-z0-9])(aarch64|arm64|armv8l?)([^a-z0-9]|$)";
  else if ([want isEqualToString:@"i386"] || [want isEqualToString:@"i686"]
           || [want isEqualToString:@"x86"])
    pattern = @"(^|[^a-z0-9])(i[3-6]86|x86(?!_)|32-?bit)([^a-z0-9]|$)";
  else
    return NO;

  NSRange hit = [lowerName rangeOfString:pattern
                                options:(NSCaseInsensitiveSearch
                                        | NSRegularExpressionSearch)];
  return hit.location != NSNotFound;
}

@implementation GWKDEAppImagePicker

#pragma mark - Version directories

+ (BOOL)isVersionDirectoryName:(NSString *)name
{
  if (name == nil)
    return NO;
  static NSRegularExpression *re = nil;
  if (re == nil)
    re = [NSRegularExpression regularExpressionWithPattern:@"^v?[0-9]+(\\.[0-9]+)*$"
                                                   options:NSCaseInsensitiveSearch
                                                     error:NULL];
  NSTextCheckingResult *hit =
    [re firstMatchInString:name options:0
                    range:NSMakeRange(0, [name length])];
  return hit != nil;
}

/* Whether version a is NEWER than version b, the plain yes/no form. */
+ (BOOL)version:(NSString *)a isNewerThan:(NSString *)b
{
  NSArray<NSString *> *ca = AGKDEVersionComponents(a);
  NSArray<NSString *> *cb = AGKDEVersionComponents(b);
  NSUInteger n = MAX([ca count], [cb count]);
  for (NSUInteger i = 0; i < n; i++)
    {
      /* A version with more components is the newer one only when the extra
       * components are not zero, which is what makes 5.3.2.1 beat 5.3.2
       * while 5.3.2.0 ties it. */
      NSUInteger va = (i < [ca count]) ? AGKDEVersionComponent([ca objectAtIndex:i]) : 0;
      NSUInteger vb = (i < [cb count]) ? AGKDEVersionComponent([cb objectAtIndex:i]) : 0;
      if (va != vb)
        return va > vb;
    }
  /* Equal numerically: fall back to the name, so the order is total and the
   * same listing always resolves the same way. */
  return [a compare:b] == NSOrderedDescending;
}

+ (NSArray<NSString *> *)versionDirectoriesFromEntryNames:
    (NSArray<NSString *> *)entryNames
{
  NSMutableArray<NSString *> *versions = [NSMutableArray array];
  for (NSString *name in entryNames)
    {
      if ([self isVersionDirectoryName:name])
        [versions addObject:name];
    }
  /* Newest first. -sortedArrayUsingComparator: wants Ascending to mean "a
   * first", which is the opposite of the "a is newer" question the
   * comparison answers, so the two are inverted here rather than inside
   * +version:isNewerThan:. */
  return [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *a,
                                                                  NSString *b) {
    if ([self version:a isNewerThan:b])
      return NSOrderedAscending;
    if ([self version:b isNewerThan:a])
      return NSOrderedDescending;
    return NSOrderedSame;
  }];
}

+ (NSString *)newestVersionDirectoryFromEntryNames:
    (NSArray<NSString *> *)entryNames
{
  NSArray<NSString *> *sorted =
    [self versionDirectoriesFromEntryNames:entryNames];
  return [sorted count] > 0 ? [sorted objectAtIndex:0] : nil;
}

#pragma mark - Choosing the file

+ (NSString *)pickFileFromNames:(NSArray<NSString *> *)names
                       appName:(NSString *)appName
                   architecture:(NSString *)architecture
                       outcome:(GWKDEPickOutcome *)outcome
                    candidates:(NSArray<NSString *> **)outCandidates
{
  if (outcome != NULL)
    *outcome = GWKDEPickNoAppImage;
  if (outCandidates != NULL)
    *outCandidates = nil;

  /* Only the file itself, and the extension test is anchored at the end and
   * case-insensitive: krita puts a digiKam-style .AppImage.sig beside every
   * build, and digiKam's own files are lower case (.appimage), while
   * labplot's directory also holds an arm64 .dmg that must not be mistaken
   * for one. */
  NSMutableArray<NSString *> *appImages = [NSMutableArray array];
  for (NSString *name in names)
    {
      if ([[name lowercaseString] hasSuffix:@".appimage"])
        [appImages addObject:name];
    }
  if ([appImages count] == 0)
    return nil;

  /* The architecture first, as a REQUIREMENT, and before any preference rule
   * runs. This is the one rule here that may leave nothing: of the five
   * applications on download.kde.org that ship AppImages, every single build
   * measured is x86-64, so there is no arm build to fall back to. Picking the
   * x86-64 file for an aarch64 user would produce a download that cannot
   * execute, which is worse than saying so.
   *
   * Order matters and is not cosmetic. A directory can hold the only build
   * that suits this machine together with a debug build of another CPU, and
   * dropping the debug one first would leave nothing and refuse an install
   * that was available. The GitHub picker does it the other way round, and can
   * afford to, because those releases do ship an arm build beside the x86-64
   * one rather than instead of it.
   *
   * The refusal reports every AppImage in the directory, before the debug
   * rule, because "it holds <the names>" should describe the directory and
   * not what survived a preference rule. */
  NSMutableArray<NSString *> *forThisMachine = [NSMutableArray array];
  for (NSString *name in appImages)
    {
      if (AGKDENamesArchitecture([name lowercaseString], architecture))
        [forThisMachine addObject:name];
    }
  if ([forThisMachine count] == 0)
    {
      if (outcome != NULL)
        *outcome = (architecture != nil && [architecture length] > 0)
          ? GWKDEPickNoAppImageForArchitecture
          : GWKDEPickNoAppImage;
      if (outCandidates != NULL)
        *outCandidates = appImages;
      return nil;
    }
  NSArray<NSString *> *candidates = forThisMachine;

  /* Debug and nightly builds. digiKam's 9.1.0 directory lists four AppImages
   * that are all the same program and the same CPU: the Qt5 and Qt6 builds
   * of the release build, and a -debug build of each. */
  NSArray<NSString *> *notDebug = [self narrow:candidates
                                       keep:^BOOL(NSString *lower) {
    return [lower rangeOfString:@"(^|[^a-z0-9])(debug|dbg|test|nightly|symbols)([^a-z0-9]|$)"
                        options:NSRegularExpressionSearch].location == NSNotFound;
  }];
  if ([notDebug count] > 0)
    candidates = notDebug;

  /* Two builds of the same release, differing only in the Qt toolkit they
   * are built against: digiKam 9.1.0 lists digiKam-9.1.0-Qt5-x86-64.appimage
   * and digiKam-9.1.0-Qt6-x86-64.appimage, and an AppImage carries its own
   * Qt, so the newer toolkit is the one to take. Name order would pick Qt5,
   * because "5" sorts before "6" as a character. */
  NSArray<NSString *> *newestQt = [self narrowToNewestQtVariant:candidates];
  if (newestQt != nil)
    candidates = newestQt;

  /* A directory can hold AppImages of more than one program. Comparing the
   * skeleton of the name with the skeleton of the app's own name tells them
   * apart, exactly as the GitHub picker does. */
  if (appName != nil && [appName length] > 0)
    {
      NSString *want = [self skeletonForName:appName];
      if ([want length] > 0)
        {
          NSMutableArray<NSString *> *same = [NSMutableArray array];
          for (NSString *name in candidates)
            {
              if ([[self skeletonForName:name] isEqualToString:want])
                [same addObject:name];
            }
          if ([same count] > 0 && [same count] < [candidates count])
            candidates = same;
        }
    }

  if ([candidates count] == 1)
    {
      if (outcome != NULL)
        *outcome = GWKDEPickChosen;
      return [candidates objectAtIndex:0];
    }

  /* Several left, and they are the same program (their skeletons agree), so
   * the difference is punctuation or digits: take them in name order, which
   * is the same tie-break the GitHub picker uses. Anything whose skeletons
   * differ is a genuine ambiguity and is reported rather than guessed. */
  if ([candidates count] > 1)
    {
      NSCountedSet *stems = [NSCountedSet set];
      for (NSString *name in candidates)
        [stems addObject:[self skeletonForName:name]];
      if ([stems count] == 1)
        {
          NSArray<NSString *> *ordered =
            [candidates sortedArrayUsingSelector:@selector(compare:)];
          if (outcome != NULL)
            *outcome = GWKDEPickChosen;
          return [ordered objectAtIndex:0];
        }
    }

  if (outcome != NULL)
    *outcome = GWKDEPickAmbiguous;
  if (outCandidates != NULL)
    *outCandidates = candidates;
  return nil;
}

#pragma mark - Narrowing

/* The name reduced to what identifies the program, for comparing a file name
 * with the app's own.
 *
 * This is +[GWAppImageAssetPicker stemForAssetName:] with one addition: a
 * trailing toolkit tag is dropped. digiKam's file is
 * digiKam-9.1.0-Qt6-x86-64.appimage, whose skeleton is "digikamqt" against an
 * app named "digiKam" whose skeleton is "digikam", so without this the rule is
 * a silent no-op for exactly the application this class exists to serve, and a
 * directory holding two Qt-tagged programs would be reported ambiguous rather
 * than resolved to the one the user asked for.
 *
 * The pattern has to allow for the fact that the digits are already gone: the
 * skeleton routine strips every digit, so by the time the tag is visible it
 * reads "qt" and not "qt6". The digits are optional for that reason, not
 * because a bare "qt" is a tag worth dropping.
 *
 * Only a TRAILING tag is dropped: it is the last thing a build name adds, and
 * a program whose own name ends that way would otherwise lose part of itself.
 * A word that merely contains it, such as "qtopia", is left alone. */
+ (NSString *)skeletonForName:(NSString *)name
{
  /* stemForAssetName: gives an empty string for a nil or empty name, and
   * -stringByReplacingMatchesInString: answers nil rather than "" for one, so
   * the empty case is settled before the replacement is asked for. */
  NSString *stem = [GWAppImageAssetPicker stemForAssetName:name];
  if ([stem length] == 0)
    return @"";

  static NSRegularExpression *trailingQt = nil;
  if (trailingQt == nil)
    trailingQt = [NSRegularExpression
                   regularExpressionWithPattern:@"qt[0-9]*$"
                  options:NSCaseInsensitiveSearch
                    error:NULL];
  return [trailingQt stringByReplacingMatchesInString:stem
                                             options:0
                                               range:NSMakeRange(0, [stem length])
                                        withTemplate:@""];
}

/* Keep the block's YES names, but only when that is a strict subset: an
 * empty result means the rule was wrong for this directory, and an unchanged
 * result means it says nothing. Both are no-ops. */
+ (NSArray<NSString *> *)narrow:(NSArray<NSString *> *)candidates
                           keep:(BOOL (^)(NSString *lowerName))keep
{
  if ([candidates count] < 2)
    return candidates;
  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  for (NSString *name in candidates)
    {
      if (keep([name lowercaseString]))
        [kept addObject:name];
    }
  if ([kept count] == 0 || [kept count] == [candidates count])
    return candidates;
  return kept;
}

/* The candidates built against the newest Qt toolkit, or nil when the word
 * "Qt" with a number is not what tells them apart. */
+ (NSArray<NSString *> *)narrowToNewestQtVariant:(NSArray<NSString *> *)candidates
{
  if ([candidates count] < 2)
    return nil;

  static NSRegularExpression *qt = nil;
  if (qt == nil)
    qt = [NSRegularExpression regularExpressionWithPattern:@"qt([0-9]+)"
                                                  options:NSCaseInsensitiveSearch
                                                    error:NULL];

  NSUInteger highest = 0;
  NSUInteger carriers = 0;
  for (NSString *name in candidates)
    {
      NSTextCheckingResult *hit =
        [qt firstMatchInString:name options:0
                        range:NSMakeRange(0, [name length])];
      if (hit == nil)
        continue;
      carriers++;
      NSUInteger n = AGKDEVersionComponent([name substringWithRange:[hit rangeAtIndex:1]]);
      if (n > highest)
        highest = n;
    }
  /* Only when every remaining name carries a Qt number is this the rule
   * doing the work; a directory where one file says Qt6 and another says
   * nothing is a different question. */
  if (carriers != [candidates count] || carriers < 2)
    return nil;

  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  for (NSString *name in candidates)
    {
      NSTextCheckingResult *hit =
        [qt firstMatchInString:name options:0
                        range:NSMakeRange(0, [name length])];
      if (hit != nil
          && AGKDEVersionComponent([name substringWithRange:[hit rangeAtIndex:1]])
               == highest)
        [kept addObject:name];
    }
  return [kept count] > 0 ? kept : nil;
}

@end
