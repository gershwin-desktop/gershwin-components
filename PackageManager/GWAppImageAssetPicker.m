/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GWAppImageAssetPicker.h"

/*
 * Every rule below was measured against the live catalog on 2026-09-28. The
 * comment on each says which real release it exists for; a rule that never
 * changed an answer is not here.
 *
 * The shape of the algorithm matters as much as the rules. Each narrowing
 * step is a no-op unless it keeps SOME but not ALL of the candidates
 * (kAGNarrow), so no single rule can ever reduce the set to nothing and
 * leave the caller with no answer at all. That is what lets an arm-only
 * release through the "prefer x86-64" step untouched.
 */

static BOOL AGNameMatches(NSString *lowerName, NSString *pattern)
{
  NSRange found = [lowerName rangeOfString:pattern
                                  options:(NSCaseInsensitiveSearch | NSRegularExpressionSearch)];
  return found.location != NSNotFound;
}

/* The "only if it narrows" primitive. Returns candidates unchanged unless
 * the block keeps a strict subset. */
typedef BOOL (^AGNarrowKeep)(NSString *lowerName);

static NSArray<NSString *> *AGNarrow(NSArray<NSString *> *candidates,
                                     AGNarrowKeep keep)
{
  if ([candidates count] < 2)
    return candidates;
  NSMutableArray<NSString *> *kept = [NSMutableArray array];
  for (NSString *name in candidates)
    {
      if (keep([name lowercaseString]))
        [kept addObject:name];
    }
  /* Keeping none would mean the rule is wrong for this release, and
     keeping all means it says nothing: both are no-ops. */
  if ([kept count] == 0 || [kept count] == [candidates count])
    return candidates;
  return kept;
}

@implementation GWAppImageAssetPicker

+ (NSString *)stemForAssetName:(NSString *)name
{
  /* Declared nullable in the header: the framework hands this whatever a
   * release happens to list, and a nil name is an empty skeleton, not a
   * reason to raise. */
  if (name == nil)
    return @"";

  NSMutableString *s = [[name lowercaseString] mutableCopy];

  /* The extension. */
  if ([[s lowercaseString] hasSuffix:@".appimage"])
    [s deleteCharactersInRange:NSMakeRange([s length] - [@".appimage" length],
                                          [@".appimage" length])];

  /* A git hash, 7 to 40 hex digits with an optional g in front. qTox
   * ships qTox-c0e9a3b7...1993dc5f-x86_64.AppImage, and without this the
   * name can never be compared with the app's own. */
  static NSRegularExpression *hash = nil;
  if (hash == nil)
    hash = [NSRegularExpression regularExpressionWithPattern:
            @"(^|[^a-z0-9])g?[0-9a-f]{7,40}([^a-z0-9]|$)" options:0 error:NULL];
  [hash replaceMatchesInString:s options:0
                        range:NSMakeRange(0, [s length])
                 withTemplate:@"$1$2"];

  /* The words that name the platform rather than the program. Order
   * matters: the 64-bit spellings have to go before the bare "linux", or
   * "linux64" leaves a stray "64" behind (harmless, since digits go next,
   * but the catalog's own order is worth keeping). */
  static NSRegularExpression *platformWord = nil;
  if (platformWord == nil)
    platformWord = [NSRegularExpression regularExpressionWithPattern:
                     @"x86_64|x86-64|amd64|x64|linux64|linux|glibc" options:0 error:NULL];
  [platformWord replaceMatchesInString:s options:0
                                range:NSMakeRange(0, [s length])
                         withTemplate:@" "];

  /* Every digit: versions, build numbers, glibc suffixes, and the digits
   * inside a name like "FreeCAD2". */
  static NSRegularExpression *digits = nil;
  if (digits == nil)
    digits = [NSRegularExpression regularExpressionWithPattern:@"[0-9]+" options:0 error:NULL];
  [digits replaceMatchesInString:s options:0 range:NSMakeRange(0, [s length]) withTemplate:@" "];

  /* Whatever is left that is a letter is the program's name. */
  NSCharacterSet *notALetter =
    [[NSCharacterSet lowercaseLetterCharacterSet] invertedSet];
  NSArray<NSString *> *letters = [s componentsSeparatedByCharactersInSet:notALetter];
  return [letters componentsJoinedByString:@""];
}

+ (NSString *)pickAssetFromNames:(NSArray<NSString *> *)names
                         appName:(NSString *)appName
                         outcome:(GWAppImagePickOutcome *)outcome
                      candidates:(NSArray<NSString *> **)outCandidates
{
  if (outcome != NULL)
    *outcome = GWAppImagePickNoAppImage;
  if (outCandidates != NULL)
    *outCandidates = nil;

  /* Only the file itself. The checksum, zsync and blockmap files next to it
   * all CONTAIN ".AppImage" - AppImageUpdate's release has twelve of them,
   * a hundred kilobytes each - so this test has to be anchored at the end
   * of the name and it has to be case-insensitive (digiKam's
   * digikam-5.9.0-01-x86-64.appimage is lower case). */
  NSMutableArray<NSString *> *appImages = [NSMutableArray array];
  for (NSString *name in names)
    {
      if ([[name lowercaseString] hasSuffix:@".appimage"])
        [appImages addObject:name];
    }
  NSArray<NSString *> *candidates = appImages;
  if ([candidates count] == 0)
    return nil;
  NSArray<NSString *> *narrowed = candidates;

  /* The single rule that does most of the work. A release that ships an
   * arm build as well puts it first, and often uploads it first too:
   * Obsidian 1.13.7 lists Obsidian-1.13.7-arm64.AppImage before
   * Obsidian-1.13.7.AppImage, and its upload timestamp is five seconds
   * earlier. Taking the first match would hand an x86-64 user an arm
   * binary. The list is the architectures that are NOT ours, matched on
   * word boundaries so that "arm" inside "armour" and the "64" in
   * "macOS10" do not count. */
  narrowed = [self narrowCandidates:narrowed
                   keepingNamesNotMatching:
                   @"(^|[^a-z0-9])(aarch64|arm64|armhf|armel|armv[0-9]l?|arm32|arm|i[3-6]86"
                   @"|x86_32|ia32|x32|ppc64(le)?|s390x|riscv64|loong(arch)?64|mips64(el)?"
                   @"|32-?bit)([^a-z0-9]|$)"];

  /* With the other CPUs gone, prefer the one that says so. x86-64 is
   * spelled six ways in the catalog (x86_64, x86-64, amd64, x64, linux64,
   * 64bit) and Audacity 3.7.9 ships one AppImage per glibc it targets. */
  narrowed = [self narrowCandidates:narrowed
                   keepingNamesMatching:
                   @"(^|[^a-z0-9])(x86[-_]64|amd64|x64|linux64|64-?bit)([^a-z0-9]|$)"];

  /* Debug, test and nightly builds. Matched on the ASSET name only:
   * qTox's whole repository is called qTox-nightly-releases and its only
   * good AppImage is a nightly, so a rule that looked at the repository or
   * the tag would delete it from the catalog. */
  narrowed = [self narrowCandidates:narrowed
                   keepingNamesNotMatching:
                   @"(^|[^a-z0-9])(debug|dbg|test|nightly|symbols)([^a-z0-9]|$)"];

  /* A release can hold several different programs: AppImageUpdate's holds
   * AppImageUpdate, appimageupdatetool and validate, for four
   * architectures each, and picking the right x86-64 file still needs to
   * pick the right PROGRAM. Comparing the skeleton of the name with the
   * skeleton of the app's own name does that. */
  if (appName != nil && [appName length] > 0)
    {
      NSString *want = [self stemForAssetName:appName];
      if ([want length] > 0)
        {
          NSMutableArray<NSString *> *same = [NSMutableArray array];
          for (NSString *name in narrowed)
            {
              if ([[self stemForAssetName:name] isEqualToString:want])
                [same addObject:name];
            }
          if ([same count] > 0 && [same count] < [narrowed count])
            narrowed = same;
        }
    }

  if ([narrowed count] == 1)
    {
      if (outcome != NULL)
        *outcome = GWAppImagePickChosen;
      return [narrowed objectAtIndex:0];
    }

  /* Several left. The catalog refuses here, and so would this, except
   * that 4KWALL - the fixture app - ships two byte-identical AppImages,
   * 4kWall-2026.9.5-x86_64.AppImage and 4kWall-x86_64.AppImage, with the
   * same size, the same sha256 and the same upload time. Refusing would
   * break an app that demonstrably works, so names that differ only by
   * punctuation and digits are taken in name order, which picks the
   * versioned one. Anything still tied is a genuine ambiguity and is
   * reported rather than guessed. */
  if ([narrowed count] > 1)
    {
      NSCountedSet *stems = [NSCountedSet set];
      for (NSString *name in narrowed)
        [stems addObject:[self stemForAssetName:name]];
      if ([stems count] == 1)
        {
          NSArray<NSString *> *ordered =
            [narrowed sortedArrayUsingSelector:@selector(compare:)];
          if (outcome != NULL)
            *outcome = GWAppImagePickChosen;
          return [ordered objectAtIndex:0];
        }
    }

  if (outcome != NULL)
    *outcome = GWAppImagePickAmbiguous;
  if (outCandidates != NULL)
    *outCandidates = narrowed;
  return nil;
}

#pragma mark - Narrowing

/* Apply one rule, but only when it actually narrows the field. */
+ (NSArray<NSString *> *)narrowCandidates:(NSArray<NSString *> *)candidates
                     keepingNamesMatching:(NSString *)pattern
{
  return [self narrowCandidates:candidates
                          keep:^BOOL(NSString *lowerName) {
                            return AGNameMatches(lowerName, pattern);
                          }];
}

+ (NSArray<NSString *> *)narrowCandidates:(NSArray<NSString *> *)candidates
                   keepingNamesNotMatching:(NSString *)pattern
{
  return [self narrowCandidates:candidates
                          keep:^BOOL(NSString *lowerName) {
                            return !AGNameMatches(lowerName, pattern);
                          }];
}

+ (NSArray<NSString *> *)narrowCandidates:(NSArray<NSString *> *)candidates
                                    keep:(AGNarrowKeep)keep
{
  return AGNarrow(candidates, keep);
}

@end
