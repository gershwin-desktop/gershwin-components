/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWKDEAppImagePicker tests.
 *
 * Every case below is a real directory from download.kde.org, with the file
 * names copied from what the server listed on 2026-09-28. The names are the
 * whole input the picker gets, so the tests need no network and cannot drift:
 * if KDE renames a build the test still says what it said, and the live
 * check is what notices.
 *
 * The recorded pages themselves are the fixtures for the index parser, and
 * they are kept as files rather than pasted in, because the thing being
 * tested there is a parser and a parser needs its real input:
 * PackageManager/Tests/kdefixtures/ holds one saved directory index per
 * case, exactly as curl wrote it.
 */

#import <Foundation/Foundation.h>
#import "GWKDEAppImagePicker.h"
#import "GWAppImageDownloader.h"

/* The index parser is private to the framework's implementation, because no
 * caller has a use for it: the entry points take a directory URL and do the
 * reading themselves. This declaration only lets the test name it, the same
 * way the live check names the resolver. */
@interface GWAppImageDownloader (IndexParsingForTests)
+ (nullable NSArray<NSString *> *)entryNamesInIndexHTML:(nullable NSString *)html;
@end

static NSString *AGKDEPick(NSArray<NSString *> *names, NSString *appName,
                           NSString *arch, GWKDEPickOutcome *outcome)
{
  return [GWKDEAppImagePicker pickFileFromNames:names
                                       appName:appName
                                   architecture:arch
                                       outcome:outcome
                                    candidates:NULL];
}

/* The recorded page, read from the fixture directory next to this file. */
static NSString *AGKDEListing(NSString *name)
{
  NSString *dir = [@"kdefixtures" stringByAppendingPathComponent:name];
  return [NSString stringWithContentsOfFile:dir
                                   encoding:NSUTF8StringEncoding
                                      error:NULL];
}

#pragma mark - The reported request: download.kde.org/stable/digikam/

/* The directory lists one version, 9.1.0, which lists four AppImages of one
 * program on one CPU: the Qt5 and Qt6 release builds and a -debug build of
 * each, each with a .sig beside it. The extension is lower case and the
 * architecture is spelled with a hyphen, so both the extension test and the
 * architecture test have to be case-insensitive and accept the hyphen. */
static BOOL testDigiKamQtAndDebugVariants(void)
{
  NSArray<NSString *> *files = @[
    @"digiKam-9.1.0-Qt5-x86-64.appimage",
    @"digiKam-9.1.0-Qt5-x86-64.appimage.sig",
    @"digiKam-9.1.0-Qt5-x86-64-debug.appimage",
    @"digiKam-9.1.0-Qt5-x86-64-debug.appimage.sig",
    @"digiKam-9.1.0-Qt6-x86-64.appimage",
    @"digiKam-9.1.0-Qt6-x86-64.appimage.sig",
    @"digiKam-9.1.0-Qt6-x86-64-debug.appimage",
    @"digiKam-9.1.0-Qt6-x86-64-debug.appimage.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"digiKam", @"x86_64", &outcome);

  /* Qt6, not Qt5: an AppImage carries its own Qt, so the newer toolkit is
   * the one to take, and name order would pick Qt5 because "5" sorts before
   * "6" as a character. */
  TAssertEqualObjects(picked, @"digiKam-9.1.0-Qt6-x86-64.appimage",
                      @"the Qt6 release build, not the debug one and not Qt5");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

#pragma mark - The architecture is a requirement, not a preference

/* Every AppImage on download.kde.org is x86-64, so on an aarch64 machine
 * there is nothing to fall back to and the honest answer is to refuse. This
 * is the deliberate difference from the GitHub picker, whose rules are all
 * no-ops rather than refusals. */
static BOOL testArmMachineIsRefusedNotGivenX86(void)
{
  NSArray<NSString *> *files = @[
    @"digiKam-9.1.0-Qt6-x86-64.appimage",
    @"digiKam-9.1.0-Qt6-x86-64.appimage.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickChosen;
  NSArray<NSString *> *candidates = nil;
  NSString *picked = [GWKDEAppImagePicker pickFileFromNames:files
                                                   appName:@"digiKam"
                                               architecture:@"aarch64"
                                                   outcome:&outcome
                                                candidates:&candidates];

  TAssertNil(picked, @"no file is chosen for a machine that cannot run one");
  TAssertTrue(outcome == GWKDEPickNoAppImageForArchitecture,
              @"outcome says the architecture, not merely that nothing matched");
  TAssertEqualObjects(candidates, @[@"digiKam-9.1.0-Qt6-x86-64.appimage"],
                      @"the error names what was on offer");
  return YES;
}

#pragma mark - The three applications with one build each

/* krita 6.0.4: capital .AppImage, an underscore in the architecture, and a
 * .sig beside it. */
static BOOL testKritaSingleBuild(void)
{
  NSArray<NSString *> *files = @[
    @"krita-6.0.4-x86_64.AppImage",
    @"krita-6.0.4-x86_64.AppImage.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"Krita", @"x86_64", &outcome);

  TAssertEqualObjects(picked, @"krita-6.0.4-x86_64.AppImage",
                      @"the one build, and not its signature");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

/* crow-translate 4.1.0 spells the platform out in full:
 * linux-gcc-x86_64. */
static BOOL testCrowTranslateFullPlatformSpelling(void)
{
  NSArray<NSString *> *files = @[
    @"crow-translate-4.1.0-linux-gcc-x86_64.AppImage",
    @"crow-translate-4.1.0-linux-gcc-x86_64.AppImage.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"Crow Translate", @"x86_64", &outcome);

  TAssertEqualObjects(picked, @"crow-translate-4.1.0-linux-gcc-x86_64.AppImage",
                      @"the one build");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

/* labplot's directory holds an AppImage, two .dmg files, an .exe and two
 * source tarballs, and no version directory at all. */
static BOOL testLabPlotFlatDirectoryIgnoresOtherFormats(void)
{
  NSArray<NSString *> *files = @[
    @"labplot-2.12.1-x86_64.AppImage",
    @"labplot-2.12.1-arm64.dmg",
    @"labplot-2.12.1-x86_64.dmg",
    @"labplot-2.12.1.exe",
    @"labplot-2.12.1.tar.xz",
    @"labplot-2.12.1.tar.xz.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"labPlot", @"x86_64", &outcome);

  TAssertEqualObjects(picked, @"labplot-2.12.1-x86_64.AppImage",
                      @"the AppImage, and neither the arm64 .dmg nor the tarball");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

#pragma mark - A directory with no AppImage at all

/* kstars 3.8.4.1 is a source tarball and nothing else. The caller walks back
 * to an older version on this outcome, so the distinction from the
 * architecture refusal matters: one means "try an older version", the other
 * means "stop and report". */
static BOOL testSourceOnlyDirectoryIsNotAnArchitectureProblem(void)
{
  NSArray<NSString *> *files = @[
    @"kstars-3.8.4.1.tar.xz",
    @"kstars-3.8.4.1.tar.xz.sig",
  ];
  GWKDEPickOutcome outcome = GWKDEPickChosen;
  NSString *picked = AGKDEPick(files, @"KStars", @"x86_64", &outcome);

  TAssertNil(picked, @"a source tarball is not an AppImage");
  TAssertTrue(outcome == GWKDEPickNoAppImage,
              @"outcome asks for an older version, not for another CPU");
  return YES;
}

#pragma mark - Ambiguity is reported, not guessed

/* Two builds of different programs in one directory, both for this machine.
 * Guessing would hand the user an application they did not ask for, so this
 * is the outcome the resolver turns into an error naming both. */
static BOOL testTwoProgramsAreReportedAsAmbiguous(void)
{
  NSArray<NSString *> *files = @[
    @"krita-6.0.4-x86_64.AppImage",
    @"krita-plugins-6.0.4-x86_64.AppImage",
  ];
  GWKDEPickOutcome outcome = GWKDEPickChosen;
  NSArray<NSString *> *candidates = nil;
  NSString *picked = [GWKDEAppImagePicker pickFileFromNames:files
                                                   appName:nil
                                               architecture:@"x86_64"
                                                   outcome:&outcome
                                                candidates:&candidates];

  TAssertNil(picked, @"nothing is chosen between two programs");
  TAssertTrue(outcome == GWKDEPickAmbiguous, @"outcome is Ambiguous");
  TAssertTrue([candidates count] == 2,
              @"both candidates are offered to the error");
  return YES;
}

#pragma mark - Version directory ordering

/* krita's directory is the real ordering trap: the raw index lists 6.0.2.1
 * before 6.0.2 and lists seven releases plus FastSketchPlugin-1.0.2,
 * FastSketchPlugin-1.1.0 and updates, which are not releases at all. */
static BOOL testKritaVersionOrderAndNonReleases(void)
{
  NSArray<NSString *> *entries = @[
    @"5.3.2.1", @"5.3.3", @"5.3.4", @"6.0.2.1", @"6.0.2", @"6.0.3", @"6.0.4",
    @"FastSketchPlugin-1.0.2", @"FastSketchPlugin-1.1.0", @"updates",
  ];
  NSArray<NSString *> *versions =
    [GWKDEAppImagePicker versionDirectoriesFromEntryNames:entries];

  TAssertEqualObjects(versions, (@[@"6.0.4", @"6.0.3", @"6.0.2.1", @"6.0.2",
                                    @"5.3.4", @"5.3.3", @"5.3.2.1"]),
                      @"newest first, numerically: 6.0.2.1 outranks 6.0.2 "
                      @"and the two FastSketchPlugin directories and updates "
                      @"are not versions");
  TAssertEqualObjects([GWKDEAppImagePicker newestVersionDirectoryFromEntryNames:entries],
                      @"6.0.4", @"the newest is 6.0.4, which is what the site serves");
  return YES;
}

/* KDE uses calendar versions (26.08) and two-digit minor versions that only
 * order correctly as numbers: "6.30" is newer than "6.7.5", which as text is
 * the other way round. */
static BOOL testVersionsThatOrderWronglyAsText(void)
{
  NSArray<NSString *> *entries = @[@"6.7.5", @"6.30", @"5.27.11", @"26.08", @"24.12"];
  NSArray<NSString *> *versions =
    [GWKDEAppImagePicker versionDirectoriesFromEntryNames:entries];

  TAssertEqualObjects([versions objectAtIndex:0], @"26.08",
                      @"a calendar version outranks a numbered one");
  TAssertTrue([versions containsObject:@"6.30"] &&
              [versions indexOfObject:@"6.30"] < [versions indexOfObject:@"6.7.5"],
              @"6.30 outranks 6.7.5, which text order gets backwards");
  TAssertTrue([versions count] == 5, @"all five are versions");
  return YES;
}

/* frameworks ships a leading "v" on some directories and not others. */
static BOOL testLeadingVIsAccepted(void)
{
  TAssertTrue([GWKDEAppImagePicker isVersionDirectoryName:@"v5.110.0"],
              @"a leading v is a version");
  TAssertTrue([GWKDEAppImagePicker isVersionDirectoryName:@"9.1.0"],
              @"a plain version is a version");
  TAssertTrue([GWKDEAppImagePicker isVersionDirectoryName:@"26.08"],
              @"a two-component version is a version");
  TAssertFalse([GWKDEAppImagePicker isVersionDirectoryName:@"updates"],
               @"updates is not a version");
  TAssertFalse([GWKDEAppImagePicker isVersionDirectoryName:@"FastSketchPlugin-1.1.0"],
               @"a plugin directory is not a version");
  TAssertFalse([GWKDEAppImagePicker isVersionDirectoryName:@"krita-6.0.4-x86_64.AppImage"],
               @"a file is not a version directory");
  TAssertFalse([GWKDEAppImagePicker isVersionDirectoryName:nil],
               @"nil is not a version directory");
  return YES;
}

/* labplot has no version directory, so the caller must be able to tell that
 * and read the application directory itself. */
static BOOL testDirectoryWithNoVersionsAtAll(void)
{
  NSArray<NSString *> *entries = @[@"labplot-2.12.1-x86_64.AppImage",
                                    @"labplot-2.12.1-arm64.dmg"];
  TAssertNil([GWKDEAppImagePicker newestVersionDirectoryFromEntryNames:entries],
             @"a flat application directory has no version to pick");
  TAssertEqualObjects([GWKDEAppImagePicker versionDirectoriesFromEntryNames:entries],
                      @[], @"and no version directories at all");
  return YES;
}

#pragma mark - Rule order, and the rules on their own

/* The architecture has to be tested BEFORE the debug rule, not after. A
 * directory can hold the only build that suits this machine together with a
 * debug build of another CPU, and dropping the debug one first would leave
 * nothing and refuse an install that was available. */
static BOOL testUsableBuildSurvivesADebugBuildOfAnotherCPU(void)
{
  NSArray<NSString *> *files = @[
    @"foo-1.0-aarch64.AppImage",
    @"foo-1.0-x86_64-debug.AppImage",
  ];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"foo", @"x86_64", &outcome);

  TAssertEqualObjects(picked, @"foo-1.0-x86_64-debug.AppImage",
                      @"the only build for this machine is chosen even "
                      @"though it is a debug build");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

/* And the refusal on the other machine must name what the directory really
 * holds, not what survived a preference rule: digiKam's 9.1.0 directory has
 * four AppImages, and "it holds" should say four. */
static BOOL testRefusalNamesEveryAppImageInTheDirectory(void)
{
  NSArray<NSString *> *files = @[
    @"digiKam-9.1.0-Qt5-x86-64.appimage",
    @"digiKam-9.1.0-Qt5-x86-64-debug.appimage",
    @"digiKam-9.1.0-Qt6-x86-64.appimage",
    @"digiKam-9.1.0-Qt6-x86-64-debug.appimage",
  ];
  GWKDEPickOutcome outcome = GWKDEPickChosen;
  NSArray<NSString *> *candidates = nil;
  [GWKDEAppImagePicker pickFileFromNames:files
                                 appName:@"digiKam"
                             architecture:@"aarch64"
                                 outcome:&outcome
                              candidates:&candidates];

  TAssertTrue(outcome == GWKDEPickNoAppImageForArchitecture,
              @"the machine has no build");
  TAssertTrue([candidates count] == 4,
              @"and the error names all four AppImages, debug ones included "
              @"(got %lu)", (unsigned long)[candidates count]);
  return YES;
}

/* The version ordering, pairwise, since through a sorted list it can only be
 * checked as a whole. */
static BOOL testVersionComparisonPairwise(void)
{
  TAssertTrue([GWKDEAppImagePicker version:@"6.0.2.1" isNewerThan:@"6.0.2"],
              @"6.0.2.1 outranks 6.0.2, which text order gets backwards");
  TAssertTrue([GWKDEAppImagePicker version:@"26.08" isNewerThan:@"24.12"],
              @"a calendar version outranks an older one");
  TAssertTrue([GWKDEAppImagePicker version:@"6.30" isNewerThan:@"6.7.5"],
              @"6.30 outranks 6.7.5, which text order also gets backwards");
  TAssertTrue([GWKDEAppImagePicker version:@"6.7" isNewerThan:@"v5.110.0"],
              @"the leading v does not affect the comparison");
  /* A trailing zero component adds no version, so 5.3.2.0 and 5.3.2 are the
   * same release. The name then breaks the tie, so the order is total and the
   * same listing always resolves the same way; which way it breaks is the
   * name comparison, not the version one. */
  TAssertTrue([GWKDEAppImagePicker version:@"5.3.2.0" isNewerThan:@"5.3.2"],
              @"a trailing zero ties on the numbers and the name decides");
  TAssertTrue([GWKDEAppImagePicker version:@"5.3.2" isNewerThan:@"5.3.2.0"]
              == ![GWKDEAppImagePicker version:@"5.3.2.0" isNewerThan:@"5.3.2"],
              @"and exactly one of the two directions holds");
  TAssertFalse([GWKDEAppImagePicker version:@"a" isNewerThan:@"b"],
               @"nil and nonsense do not claim to be newer");
  return YES;
}

/* The narrowing primitive, on its own: a rule that keeps all of nothing is a
 * no-op in both directions, which is what keeps a rule from deleting a usable
 * build. */
static BOOL testNarrowingIsANoOpUnlessItNarrows(void)
{
  NSArray<NSString *> *two = @[@"a-x86_64.AppImage", @"b-x86_64.AppImage"];

  TAssertEqualObjects([GWKDEAppImagePicker narrow:two keep:^BOOL(NSString *n) {
                        return [n hasPrefix:@"a"];
                      }], @[@"a-x86_64.AppImage"],
                      @"keeping one of two narrows");

  TAssertEqualObjects([GWKDEAppImagePicker narrow:two keep:^BOOL(NSString *n) {
                        return YES;
                      }], two, @"keeping both of two is a no-op");

  TAssertEqualObjects([GWKDEAppImagePicker narrow:two keep:^BOOL(NSString *n) {
                        return NO;
                      }], two, @"keeping none of two is a no-op, so a rule "
                      @"wrong for this directory cannot empty the field");

  TAssertEqualObjects([GWKDEAppImagePicker narrow:@[ @"only" ] keep:^BOOL(NSString *n) {
                        return NO;
                      }], @[ @"only" ], @"a single candidate is never narrowed");
  return YES;
}

/* The Qt rule, and the case where it must not fire: a directory where only
 * some names carry a Qt number is a different question, and the rule stays
 * out of it. */
static BOOL testQtRuleNeedsEveryNameToCarryIt(void)
{
  NSArray<NSString *> *both = @[@"app-1.0-Qt5-x86_64.AppImage",
                                @"app-1.0-Qt6-x86_64.AppImage"];
  TAssertEqualObjects([GWKDEAppImagePicker narrowToNewestQtVariant:both],
                      @[@"app-1.0-Qt6-x86_64.AppImage"],
                      @"the newest Qt wins");

  NSArray<NSString *> *mixed = @[@"app-1.0-Qt5-x86_64.AppImage",
                                 @"app-1.0-x86_64.AppImage"];
  TAssertNil([GWKDEAppImagePicker narrowToNewestQtVariant:mixed],
             @"when only one name says Qt, the rule does not apply");

  TAssertNil([GWKDEAppImagePicker narrowToNewestQtVariant:@[ @"one.AppImage" ]],
             @"and never on a single candidate");
  return YES;
}

/* The skeleton drops a trailing toolkit tag, which is what lets the name rule
 * tell two Qt-tagged programs apart instead of reporting them ambiguous. */
static BOOL testSkeletonDropsATrailingToolkitTag(void)
{
  TAssertEqualObjects([GWKDEAppImagePicker skeletonForName:@"digiKam"],
                      @"digikam", @"an app name reduces to itself");
  TAssertEqualObjects([GWKDEAppImagePicker skeletonForName:
                         @"digiKam-9.1.0-Qt6-x86-64.appimage"],
                      @"digikam", @"a Qt-tagged build reduces to the same thing");
  TAssertEqualObjects([GWKDEAppImagePicker skeletonForName:@"krita"],
                      @"krita", @"and so does a plain one");
  TAssertEqualObjects([GWKDEAppImagePicker skeletonForName:@""], @"",
                      @"an empty name is empty rather than a reason to raise");
  return YES;
}

/* Two programs, both Qt-tagged: the name rule is what resolves it, and
 * without the skeleton fix this pair would be reported ambiguous. */
static BOOL testTwoQtTaggedProgramsAreToldApart(void)
{
  NSArray<NSString *> *files = @[
    @"digikam-9.1.0-Qt6-x86-64.appimage",
    @"digikam-gimp-qt5-x86_64.AppImage",
  ];
  GWKDEPickOutcome outcome = GWKDEPickChosen;
  NSString *picked = AGKDEPick(files, @"digiKam", @"x86_64", &outcome);

  TAssertEqualObjects(picked, @"digikam-9.1.0-Qt6-x86-64.appimage",
                      @"the build whose skeleton matches the app's");
  TAssertTrue(outcome == GWKDEPickChosen, @"outcome is Chosen");
  return YES;
}

#pragma mark - Parsing the recorded index pages

/* The real page, through the real parser: the version directories and the
 * one file, with the site's own chrome (the KDE footer links, the column
 * sort links, the "Parent Directory" row) left out. */
static BOOL testRecordedIndexPageParses(void)
{
  NSString *html = AGKDEListing(@"digikam-listing.html");
  TAssertNotNil(html, @"the recorded digikam index is readable");

  NSArray<NSString *> *entries = [GWAppImageDownloader entryNamesInIndexHTML:html];
  TAssertNotNil(entries, @"a page with a Parent Directory row is an index");
  TAssertTrue([entries containsObject:@"9.1.0"],
              @"the version directory is found");
  TAssertEqualObjects([GWKDEAppImagePicker newestVersionDirectoryFromEntryNames:entries],
                      @"9.1.0", @"and it is the only one");

  NSString *inner = AGKDEListing(@"digikam-9.1.0-listing.html");
  NSArray<NSString *> *files = [GWAppImageDownloader entryNamesInIndexHTML:inner];
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  NSString *picked = AGKDEPick(files, @"digiKam", @"x86_64", &outcome);
  TAssertEqualObjects(picked, @"digiKam-9.1.0-Qt6-x86-64.appimage",
                      @"the Qt6 release build out of the real page");
  return YES;
}

/* A real KDE application page rather than a directory index. It has links,
 * but none of them is a file in a directory, and reading them as a file list
 * would resolve a download page to a bug-report link. */
static BOOL testOrdinaryWebPageIsNotAnIndex(void)
{
  NSString *html = AGKDEListing(@"not-a-listing.html");
  TAssertNotNil(html, @"the recorded application page is readable");
  TAssertNil([GWAppImageDownloader entryNamesInIndexHTML:html],
             @"a page with no Parent Directory row is refused, not parsed");
  TAssertNil([GWAppImageDownloader entryNamesInIndexHTML:@""],
             @"an empty page is not an index");
  TAssertNil([GWAppImageDownloader entryNamesInIndexHTML:nil],
             @"no page is not an index");
  return YES;
}

/* krita's index is the one with the non-release directories in it, and
 * labplot's is the flat one, so both shapes are parsed from real pages. */
static BOOL testRecordedFlatAndMixedPagesParse(void)
{
  NSArray<NSString *> *krita =
    [GWAppImageDownloader entryNamesInIndexHTML:
       AGKDEListing(@"krita-listing.html")];
  TAssertNotNil(krita, @"krita's index parses");
  TAssertTrue([krita containsObject:@"updates"],
              @"a non-release directory is still an entry");
  TAssertEqualObjects([GWKDEAppImagePicker newestVersionDirectoryFromEntryNames:krita],
                      @"6.0.4", @"and the newest version among them is 6.0.4");

  NSArray<NSString *> *labplot =
    [GWAppImageDownloader entryNamesInIndexHTML:
       AGKDEListing(@"labplot-listing.html")];
  TAssertNotNil(labplot, @"labplot's index parses");
  TAssertNil([GWKDEAppImagePicker newestVersionDirectoryFromEntryNames:labplot],
             @"labplot has no version directory");
  GWKDEPickOutcome outcome = GWKDEPickNoAppImage;
  TAssertEqualObjects(AGKDEPick(labplot, @"labPlot", @"x86_64", &outcome),
                      @"labplot-2.12.1-x86_64.AppImage",
                      @"so its own directory is read directly");
  return YES;
}

void AGRegisterKDEAppImagePickerTests(void)
{
  runTest(@"testDigiKamQtAndDebugVariants", ^{ return testDigiKamQtAndDebugVariants(); });
  runTest(@"testArmMachineIsRefusedNotGivenX86", ^{ return testArmMachineIsRefusedNotGivenX86(); });
  runTest(@"testKritaSingleBuild", ^{ return testKritaSingleBuild(); });
  runTest(@"testCrowTranslateFullPlatformSpelling", ^{ return testCrowTranslateFullPlatformSpelling(); });
  runTest(@"testLabPlotFlatDirectoryIgnoresOtherFormats", ^{ return testLabPlotFlatDirectoryIgnoresOtherFormats(); });
  runTest(@"testSourceOnlyDirectoryIsNotAnArchitectureProblem", ^{ return testSourceOnlyDirectoryIsNotAnArchitectureProblem(); });
  runTest(@"testTwoProgramsAreReportedAsAmbiguous", ^{ return testTwoProgramsAreReportedAsAmbiguous(); });
  runTest(@"testKritaVersionOrderAndNonReleases", ^{ return testKritaVersionOrderAndNonReleases(); });
  runTest(@"testVersionsThatOrderWronglyAsText", ^{ return testVersionsThatOrderWronglyAsText(); });
  runTest(@"testLeadingVIsAccepted", ^{ return testLeadingVIsAccepted(); });
  runTest(@"testDirectoryWithNoVersionsAtAll", ^{ return testDirectoryWithNoVersionsAtAll(); });
  runTest(@"testUsableBuildSurvivesADebugBuildOfAnotherCPU", ^{ return testUsableBuildSurvivesADebugBuildOfAnotherCPU(); });
  runTest(@"testRefusalNamesEveryAppImageInTheDirectory", ^{ return testRefusalNamesEveryAppImageInTheDirectory(); });
  runTest(@"testVersionComparisonPairwise", ^{ return testVersionComparisonPairwise(); });
  runTest(@"testNarrowingIsANoOpUnlessItNarrows", ^{ return testNarrowingIsANoOpUnlessItNarrows(); });
  runTest(@"testQtRuleNeedsEveryNameToCarryIt", ^{ return testQtRuleNeedsEveryNameToCarryIt(); });
  runTest(@"testSkeletonDropsATrailingToolkitTag", ^{ return testSkeletonDropsATrailingToolkitTag(); });
  runTest(@"testTwoQtTaggedProgramsAreToldApart", ^{ return testTwoQtTaggedProgramsAreToldApart(); });
  runTest(@"testRecordedIndexPageParses", ^{ return testRecordedIndexPageParses(); });
  runTest(@"testOrdinaryWebPageIsNotAnIndex", ^{ return testOrdinaryWebPageIsNotAnIndex(); });
  runTest(@"testRecordedFlatAndMixedPagesParse", ^{ return testRecordedFlatAndMixedPagesParse(); });
}
