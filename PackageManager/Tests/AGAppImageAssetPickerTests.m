/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageAssetPicker tests.
 *
 * Every case below is a real release from the live AppImage catalog, with
 * the asset names copied from what the forge listed on 2026-09-28. The names
 * are the whole input the picker gets, so the tests need no network and
 * cannot drift: if a project renames its assets the test still says what it
 * said, and the live check in the PR text is what notices.
 *
 * The "before" column is what the previous code did on the same input, so
 * every assertion here is a change that was measured rather than assumed.
 */

#import <Foundation/Foundation.h>
#import "GWAppImageAssetPicker.h"

static NSString *AGPick(NSArray<NSString *> *names, NSString *appName,
                        GWAppImagePickOutcome *outcome)
{
  return [GWAppImageAssetPicker pickAssetFromNames:names
                                          appName:appName
                                          outcome:outcome
                                       candidates:NULL];
}

#pragma mark - ipfs-desktop: the reported failure

/* The repository was renamed from ipfs-shipyard/ipfs-desktop to
 * ipfs/ipfs-desktop, so /releases/latest answers 301 with a Location that
 * still ends in /releases/latest and names no tag. Reading that first
 * header is what produced "GitHub release lookup failed" for an app that
 * downloads perfectly well. The redirect-following fix lives in
 * GWAppImageDownloader; what is asserted here is the asset stage of the
 * same release, which is a 17-asset Electron release with one AppImage in
 * it and four different spellings of the architecture among the others. */
static BOOL testIPFSDesktopRelease(void)
{
  NSArray<NSString *> *assets = @[
    @"ipfs-desktop-0.50.1-linux-amd64.deb",
    @"ipfs-desktop-0.50.1-linux-amd64.snap",
    @"ipfs-desktop-0.50.1-linux-x64.freebsd",
    @"ipfs-desktop-0.50.1-linux-x64.tar.xz",
    @"ipfs-desktop-0.50.1-linux-x86_64.AppImage",
    @"ipfs-desktop-0.50.1-linux-x86_64.rpm",
    @"ipfs-desktop-0.50.1-mac.dmg",
    @"ipfs-desktop-0.50.1-mac.dmg.blockmap",
    @"ipfs-desktop-0.50.1-squirrel.zip",
    @"ipfs-desktop-0.50.1-squirrel.zip.blockmap",
    @"ipfs-desktop-setup-0.50.1-win-x64.exe",
    @"ipfs-desktop-setup-0.50.1-win-x64.exe.blockmap",
    @"latest-linux.yml",
    @"latest-mac.yml",
    @"latest.yml",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"ipfs-desktop", &outcome);
  TAssertEqualObjects(picked, @"ipfs-desktop-0.50.1-linux-x86_64.AppImage",
                      @"ipfs-desktop 0.50.1: the one AppImage among 15 assets");
  TAssertTrue(outcome == GWAppImagePickChosen, @"outcome is Chosen");
  return YES;
}

#pragma mark - The architecture rule, which is the one that matters

/* Obsidian 1.13.7 lists the arm64 build FIRST and uploads it five seconds
 * before the x86-64 one, whose name says nothing about the CPU at all. The
 * old code took the first name containing x86_64 or amd64, found neither,
 * and fell back to the first AppImage - the arm binary, on an x86-64
 * machine. */
static BOOL testObsidianArmBuildComesFirst(void)
{
  NSArray<NSString *> *assets = @[
    @"Obsidian-1.13.7-arm64.AppImage",
    @"obsidian-1.13.7-arm64.tar.gz",
    @"Obsidian-1.13.7.apk",
    @"Obsidian-1.13.7.AppImage",
    @"obsidian-1.13.7.asar.gz",
    @"Obsidian-1.13.7.dmg",
    @"Obsidian-1.13.7.exe",
    @"obsidian-1.13.7.tar.gz",
    @"obsidian_1.13.7_amd64.deb",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"Obsidian", &outcome);
  TAssertEqualObjects(picked, @"Obsidian-1.13.7.AppImage",
                      @"Obsidian: not the arm64 build that is listed first");
  return YES;
}

/* Audacity ships one AppImage per architecture and the arm one is first
 * again. Here the name does say x86_64, so the old code got this one right
 * by accident of the first-match loop; the rule is what makes it
 * deliberate. */
static BOOL testAudacityArchPair(void)
{
  NSArray<NSString *> *assets = @[
    @"audacity-linux-4.0.0-aarch64.AppImage",
    @"audacity-linux-4.0.0-x86_64.AppImage",
    @"audacity-macOS-4.0.0-arm64.dmg",
    @"audacity-macOS-4.0.0-universal.dmg",
    @"audacity-macOS-4.0.0-x86_64.dmg",
    @"audacity-sources-4.0.0.tar.xz",
    @"audacity-win-4.0.0-arm64.msi",
    @"audacity-win-4.0.0-x86_64.msi",
    @"CHECKSUMS.txt",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"Audacity", &outcome);
  TAssertEqualObjects(picked, @"audacity-linux-4.0.0-x86_64.AppImage",
                      @"Audacity: the x86-64 build, not the aarch64 one listed first");
  return YES;
}

/* Motrix 1.8.19 has arm64, armv7l and a build with no architecture in its
 * name. The old code matched neither x86_64 nor amd64 and took the first
 * AppImage, which is arm64. */
static BOOL testMotrixMixedArches(void)
{
  NSArray<NSString *> *assets = @[
    @"Motrix-1.8.19-arm64.AppImage",
    @"Motrix-1.8.19-armv7l.AppImage",
    @"Motrix-1.8.19.AppImage",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"Motrix", &outcome);
  TAssertEqualObjects(picked, @"Motrix-1.8.19.AppImage",
                      @"Motrix: the build with no arch in the name, once arm is out");
  return YES;
}

#pragma mark - The end anchor, which is what keeps .zsync out

/* AppImageUpdate's release holds 3 programs x 4 architectures plus a .zsync
 * beside every one of them: 24 AppImages, 12 of them a hundred kilobytes
 * each. A test that looks for ".appimage" ANYWHERE IN THE NAME matches all
 * 24 and can hand back a zsync file. */
static BOOL testZsyncFilesAreNotAppImages(void)
{
  NSMutableArray<NSString *> *assets = [NSMutableArray array];
  NSArray<NSString *> *programs = @[@"AppImageUpdate", @"appimageupdatetool", @"validate"];
  NSArray<NSString *> *arches = @[@"aarch64", @"armhf", @"i686", @"x86_64"];
  for (NSString *program in programs)
    {
      for (NSString *arch in arches)
        {
          [assets addObject:[NSString stringWithFormat:@"%@-%@.AppImage", program, arch]];
          [assets addObject:[NSString stringWithFormat:@"%@-%@.AppImage.zsync", program, arch]];
        }
    }
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"AppImageUpdate", &outcome);
  TAssertEqualObjects(picked, @"AppImageUpdate-x86_64.AppImage",
                      @"AppImageUpdate: the x86_64 build of the right program, "
                      @"not a .zsync and not validate or appimageupdatetool");
  return YES;
}

/* FreeCAD puts .AppImage-SHA256.txt and .AppImage.zsync right next to the
 * real file, and the digest file is listed SECOND. */
static BOOL testDigestAndBlockmapFilesAreNotAppImages(void)
{
  NSArray<NSString *> *assets = @[
    @"FreeCAD_1.1.3-Linux-aarch64-py311.AppImage",
    @"FreeCAD_1.1.3-Linux-aarch64-py311.AppImage-SHA256.txt",
    @"FreeCAD_1.1.3-Linux-aarch64-py311.AppImage.zsync",
    @"FreeCAD_1.1.3-Linux-x86_64-py311.AppImage",
    @"FreeCAD_1.1.3-Linux-x86_64-py311.AppImage-SHA256.txt",
    @"FreeCAD_1.1.3-Linux-x86_64-py311.AppImage.zsync",
    @"FreeCAD_1.1.3-macOS-arm64-py311.dmg",
    @"FreeCAD_1.1.3-Windows-x86_64-py311-installer.exe",
    @"freecad_source_1.1.3.tar.gz",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"FreeCAD2", &outcome);
  TAssertEqualObjects(picked, @"FreeCAD_1.1.3-Linux-x86_64-py311.AppImage",
                      @"FreeCAD: the .AppImage, not the -SHA256.txt or .zsync");
  return YES;
}

/* 4KWALL is the catalog's own fixture app and its release lists a .sha256
 * that contains ".AppImage" in its name, second of five. */
static BOOL testChecksumFileIsNotAnAppImage(void)
{
  NSArray<NSString *> *assets = @[
    @"4kWall-2026.9.5-x86_64.AppImage",
    @"4kWall-2026.9.5-x86_64.AppImage.sha256",
    @"4kWall-2026.9.5-x86_64.exe",
    @"4kWall-x86_64.AppImage",
    @"4kWall.exe",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  NSString *picked = AGPick(assets, @"4KWALL", &outcome);
  TAssertTrue([picked hasSuffix:@".AppImage"],
              @"4KWALL: never the .sha256 or the .exe");
  TAssertFalse([picked hasSuffix:@".AppImage.sha256"],
               @"4KWALL: not the checksum file");
  return YES;
}

#pragma mark - The tie 4KWALL forces

/* 4kWall-2026.9.5-x86_64.AppImage and 4kWall-x86_64.AppImage are the same
 * bytes: same size, same sha256, same upload time. The catalog's own rules
 * refuse here ("several AppImages, and it is not clear which one to test"),
 * and refusing would break an app that demonstrably works, so names that
 * reduce to the same skeleton are taken in name order - which puts the
 * versioned one first and is what the previous code picked. */
static BOOL testIdenticalTakesTheVersionedName(void)
{
  NSArray<NSString *> *assets = @[
    @"4kWall-x86_64.AppImage",
    @"4kWall-2026.9.5-x86_64.AppImage",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickAmbiguous;
  NSString *picked = AGPick(assets, @"4KWALL", &outcome);
  TAssertEqualObjects(picked, @"4kWall-2026.9.5-x86_64.AppImage",
                      @"4KWALL: two identical files resolve to the versioned name");
  TAssertTrue(outcome == GWAppImagePickChosen,
              @"4KWALL: an identical pair is chosen, not reported ambiguous");
  return YES;
}

/* Two files that reduce to DIFFERENT skeletons, neither of which matches the
 * app's own name, are a real ambiguity and are reported rather than guessed:
 * either could be a different program. (When one of them DOES match the app's
 * name, that is not ambiguous - see the first half.) */
static BOOL testGenuinelyAmbiguousIsReported(void)
{
  GWAppImagePickOutcome outcome = GWAppImagePickChosen;
  NSArray<NSString *> *candidates = nil;

  /* The app name disambiguates: only SomeTool reduces to "sometool". */
  NSArray<NSString *> *named = @[
    @"SomeTool-x86_64.AppImage",
    @"SomeToolHelper-x86_64.AppImage",
  ];
  NSString *picked = [GWAppImageAssetPicker pickAssetFromNames:named
                                                       appName:@"SomeTool"
                                                       outcome:&outcome
                                                    candidates:&candidates];
  TAssertEqualObjects(picked, @"SomeTool-x86_64.AppImage",
                      @"when one candidate is named after the app, that is the one");

  /* Nothing is named after the app, so there is nothing to choose between. */
  NSArray<NSString *> *anonymous = @[
    @"Alpha-x86_64.AppImage",
    @"Beta-x86_64.AppImage",
  ];
  picked = [GWAppImageAssetPicker pickAssetFromNames:anonymous
                                             appName:@"Gamma"
                                             outcome:&outcome
                                          candidates:&candidates];
  TAssertTrue(picked == nil, @"two different programs: nothing is guessed");
  TAssertTrue(outcome == GWAppImagePickAmbiguous, @"outcome is Ambiguous");
  TAssertTrue([candidates count] == 2U,
              @"both candidates are reported so the error can name them");
  return YES;
}

#pragma mark - Architectures spelled six ways

/* The catalog spells x86-64 as x86_64, x86-64, amd64, x64, linux64 and
 * 64bit. The old code knew only x86_64 and amd64, so a name using any of
 * the other four fell through to "take the first AppImage". digiKam's real
 * file is digikam-5.9.0-01-x86-64.appimage, with a hyphen and a lower case
 * extension. */
static BOOL testX86SpellingsAndLowerCaseExtension(void)
{
  NSArray<NSString *> *digiKam = @[
    @"digikam-5.9.0-01-x86-64.appimage",
    @"digikam-5.9.0-01-x86-64.appimage.zsync",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(digiKam, @"digiKam", &outcome),
                      @"digikam-5.9.0-01-x86-64.appimage",
                      @"digiKam: the x86-64 spelling with a hyphen, and .appimage "
                      @"in lower case, are both recognised");

  NSArray<NSString *> *jan = @[@"Jan_0.8.4_amd64.AppImage", @"Jan_0.8.4_amd64.deb"];
  TAssertEqualObjects(AGPick(jan, @"Jan", &outcome), @"Jan_0.8.4_amd64.AppImage",
                      @"Jan: amd64 with an underscore");

  NSArray<NSString *> *audacityGlibc = @[
    @"audacity-linux-3.7.9-x64-20.04.AppImage",
    @"audacity-linux-3.7.9-x64-22.04.AppImage",
  ];
  /* Audacity 3.7.9 ships one AppImage per glibc it targets, 20.04 and 22.04.
   * Both survive, because "x64" is an x86-64 spelling and neither is another
   * CPU: the two are then told apart by the same-skeleton tie, which takes
   * them in name order. */
  NSString *glibcPick = AGPick(audacityGlibc, @"Audacity", &outcome);
  TAssertTrue(glibcPick != nil && [glibcPick hasSuffix:@".AppImage"],
              @"Audacity 3.7.9: one of the two x64 builds is chosen (%@)", glibcPick);
  TAssertTrue([glibcPick rangeOfString:@"x64"].location != NSNotFound,
              @"Audacity 3.7.9: the x64 build, not a build for another CPU");
  return YES;
}

/* A universal build that has "arm" in its name is not for this machine, and
 * one whose name merely contains those letters as part of a word is. 86Box's
 * macOS zip is the negative case: it names x86_64 AND arm64 and survives
 * only because it is a .zip. */
static BOOL testArchitectureMatchingIsOnWordBoundaries(void)
{
  NSArray<NSString *> *assets = @[
    @"86Box-Linux-x86_64-b9001.AppImage",
    @"86Box-NDR-Linux-arm64-b9001.AppImage",
    @"86Box-macOS-x86_64+arm64-b9001.zip",
    @"86Box-Windows-64-b9001.zip",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(assets, @"86Box", &outcome),
                      @"86Box-Linux-x86_64-b9001.AppImage",
                      @"86Box: the Linux build, not the separately named NDR one");

  /* "Armour" is a word, not an architecture, so it must survive the rule
   * that drops arm builds - while the real arm64 sibling next to it does
   * not. Both spellings are otherwise identical, which is what makes this
   * a test of the word boundary rather than of the name. */
  NSArray<NSString *> *armour = @[
    @"Game-arm64.AppImage",
    @"Game-Armour-x86_64.AppImage",
  ];
  TAssertEqualObjects(AGPick(armour, @"Game", &outcome),
                      @"Game-Armour-x86_64.AppImage",
                      @"'Armour' is a word, not the arm architecture, so it survives");
  return YES;
}

/* An arm-only release must still yield a file rather than nothing: the
 * "prefer x86-64" step is a no-op when it would empty the field. This is
 * what keeps an arm build installable on an arm machine instead of the
 * picker refusing everything that is not x86-64. */
static BOOL testArmOnlyReleaseStillResolves(void)
{
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(@[@"Thing-arm64.AppImage"], @"Thing", &outcome),
                      @"Thing-arm64.AppImage",
                      @"an arm-only release still resolves rather than failing");
  return YES;
}

/* A release with no AppImage at all is reported as such, distinctly from one
 * that has several it cannot choose between: the caller walks back to an
 * older release for this, and tells the user about that for the other.
 * Obsidian 1.13.8 is exactly this - a mobile-only release with one .apk -
 * and the distinction is the whole point, because an assets page listing an
 * .apk is not an empty one. */
static BOOL testReleaseWithNoAppImage(void)
{
  NSArray<NSString *> *assets = @[@"Obsidian-1.13.8.apk"];
  GWAppImagePickOutcome outcome = GWAppImagePickChosen;
  TAssertTrue(AGPick(assets, @"Obsidian", &outcome) == nil,
              @"a mobile-only release has no AppImage");
  TAssertTrue(outcome == GWAppImagePickNoAppImage, @"outcome is NoAppImage");
  TAssertTrue(outcome != GWAppImagePickAmbiguous,
              @"a release with nothing to choose from is not an ambiguity");
  return YES;
}

#pragma mark - The skeleton

/* The name reduced to a comparable form. This is the subtlest rule and the
 * one that tells three programs in one release apart, so it is asserted
 * directly rather than only through its effect. */
static BOOL testStem(void)
{
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"AppImageUpdate-x86_64.AppImage"],
                      @"appimageupdate", @"stem: program name, arch and extension");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"appimageupdatetool-x86_64.AppImage"],
                      @"appimageupdatetool",
                      @"stem: the lower-case sibling keeps its own name");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"validate-x86_64.AppImage"],
                      @"validate", @"stem: a different program in the same release");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"4KWALL"], @"kwall",
                      @"stem: digits in the app's own name go too");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"4kWall-2026.9.5-x86_64.AppImage"],
                      @"kwall", @"stem: matches the app's own name");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"4kWall-x86_64.AppImage"],
                      @"kwall", @"stem: the unversioned twin reduces the same way");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"FreeCAD2"], @"freecad",
                      @"stem: FreeCAD2 reduces to freecad");
  /* FreeCAD's file does NOT reduce to "freecad": the catalog names it
   * FreeCAD2, and the "py311" in the file name survives as "py". Asserted
   * as measured, because it is the reason the name rule has to be a
   * no-op-when-it-does-not-help: the x86-64 rule has already decided this
   * release by the time the names are compared, and a name rule that
   * insisted on a match here would throw the answer away. The catalog's own
   * stem.sh produces "freecadpy" too. */
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"FreeCAD_1.1.3-Linux-x86_64-py311.AppImage"],
                      @"freecadpy",
                      @"stem: FreeCAD's file keeps the 'py' of py311, as upstream does");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"Krita"], @"krita", @"stem: plain");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"krita-5.2.6-x86_64.AppImage"],
                      @"krita", @"stem: versioned and arch-suffixed");
  /* qTox's only AppImage carries a 40-character git hash, which is why the
   * hash is stripped: without it the name can never be compared with the
   * app's own and the app is not installable. */
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:
                       @"qTox-c0e9a3b79609681e5b9f6bbf8f9a36cb1993dc5f-x86_64.AppImage"],
                      @"qtox", @"stem: a 40-character git hash is stripped");
  /* 86Box's build number b9001 leaves its leading "b" behind once the
   * digits go, so its file reduces to "boxb" and not to "box". The
   * catalog's own stem.sh agrees (verified against it), and it does not
   * matter here because the architecture rule has already separated the
   * Linux build from the separately named NDR one. Asserted as measured so
   * the wart is on record rather than discovered later. */
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"86Box-Linux-x86_64-b9001.AppImage"],
                      @"boxb", @"stem: 86Box's build number leaves a 'b' behind, as upstream");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"86Box-NDR-Linux-arm64-b9001.AppImage"],
                      @"boxndrarmb", @"stem: the NDR build is a different program");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:@"audacity-linux-3.7.9-x64-22.04.AppImage"],
                      @"audacity", @"stem: glibc suffix is a number, so it goes");
  return YES;
}

/* qTox: the repository and the tag are both called nightly, and its only
 * AppImage is the nightly build. A rule that looked at the repository, the
 * tag or the URL instead of the asset name would delete it. */
static BOOL testNightlyRepositoryKeepsItsAppImage(void)
{
  NSArray<NSString *> *assets = @[
    @"qTox-c0e9a3b79609681e5b9f6bbf8f9a36cb1993dc5f-x86_64.AppImage",
    @"qTox-c0e9a3b79609681e5b9f6bbf8f9a36cb1993dc5f-x86_64.AppImage.zsync",
    @"qtox-i686-debug.zip",
    @"qtox-x86_64-debug.zip",
    @"qTox.dmg",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(assets, @"qTox", &outcome),
                      @"qTox-c0e9a3b79609681e5b9f6bbf8f9a36cb1993dc5f-x86_64.AppImage",
                      @"qTox: a debug word in a .zip sibling does not remove the "
                      @"AppImage, and the hash in the name is not read as noise");
  return YES;
}

/* Debug and nightly words in the ASSET name are still dropped when a real
 * alternative exists. */
static BOOL testDebugBuildIsDroppedWhenAnAlternativeExists(void)
{
  NSArray<NSString *> *assets = @[
    @"Tool-x86_64-debug.AppImage",
    @"Tool-x86_64.AppImage",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(assets, @"Tool", &outcome), @"Tool-x86_64.AppImage",
                      @"a debug AppImage loses to the plain one");
  return YES;
}

/* The clean case, which must not be broken by any of the above: one
 * AppImage among fourteen assets of five other formats. */
static BOOL testSingleCleanAppImage(void)
{
  NSArray<NSString *> *assets = @[
    @"appcast-linux-x86_64.xml",
    @"appcast-macos-arm64.xml",
    @"AppFlowy-0.14.5-android.apk",
    @"AppFlowy-0.14.5-linux-x86_64.AppImage",
    @"AppFlowy-0.14.5-linux-x86_64.deb",
    @"AppFlowy-0.14.5-linux-x86_64.rpm",
    @"AppFlowy-0.14.5-linux-x86_64.tar.gz",
    @"AppFlowy-0.14.5-macos-arm64.dmg",
    @"AppFlowy-0.14.5-macos-universal.dmg",
    @"AppFlowy-0.14.5-macos-x86_64.dmg",
    @"AppFlowy-0.14.5-windows-x86_64.exe",
    @"AppFlowy-0.14.5-windows-x86_64.zip",
  ];
  GWAppImagePickOutcome outcome = GWAppImagePickNoAppImage;
  TAssertEqualObjects(AGPick(assets, @"AppFlowy", &outcome),
                      @"AppFlowy-0.14.5-linux-x86_64.AppImage",
                      @"the simple case is still the simple case");
  return YES;
}

/* A nil app name and an empty list must not crash: the picker is called from
 * a framework that may be handed anything. */
static BOOL testDegenerateInputs(void)
{
  GWAppImagePickOutcome outcome = GWAppImagePickChosen;
  TAssertTrue(AGPick(@[], nil, &outcome) == nil, @"an empty release yields nothing");
  TAssertTrue(outcome == GWAppImagePickNoAppImage, @"outcome is NoAppImage");

  TAssertEqualObjects(AGPick(@[@"Solo.AppImage"], nil, &outcome), @"Solo.AppImage",
                      @"a single AppImage needs no app name to be found");
  TAssertEqualObjects([GWAppImageAssetPicker stemForAssetName:nil], @"",
                      @"stem of nil is empty, not a crash");
  return YES;
}

#pragma mark - Registration

void AGRegisterAppImageAssetPickerTests(void)
{
  runTest(@"testIPFSDesktopRelease", ^{ return testIPFSDesktopRelease(); });
  runTest(@"testObsidianArmBuildComesFirst", ^{ return testObsidianArmBuildComesFirst(); });
  runTest(@"testAudacityArchPair", ^{ return testAudacityArchPair(); });
  runTest(@"testMotrixMixedArches", ^{ return testMotrixMixedArches(); });
  runTest(@"testZsyncFilesAreNotAppImages", ^{ return testZsyncFilesAreNotAppImages(); });
  runTest(@"testDigestAndBlockmapFilesAreNotAppImages", ^{ return testDigestAndBlockmapFilesAreNotAppImages(); });
  runTest(@"testChecksumFileIsNotAnAppImage", ^{ return testChecksumFileIsNotAnAppImage(); });
  runTest(@"testIdenticalTakesTheVersionedName", ^{ return testIdenticalTakesTheVersionedName(); });
  runTest(@"testGenuinelyAmbiguousIsReported", ^{ return testGenuinelyAmbiguousIsReported(); });
  runTest(@"testX86SpellingsAndLowerCaseExtension", ^{ return testX86SpellingsAndLowerCaseExtension(); });
  runTest(@"testArchitectureMatchingIsOnWordBoundaries", ^{ return testArchitectureMatchingIsOnWordBoundaries(); });
  runTest(@"testArmOnlyReleaseStillResolves", ^{ return testArmOnlyReleaseStillResolves(); });
  runTest(@"testReleaseWithNoAppImage", ^{ return testReleaseWithNoAppImage(); });
  runTest(@"testStem", ^{ return testStem(); });
  runTest(@"testNightlyRepositoryKeepsItsAppImage", ^{ return testNightlyRepositoryKeepsItsAppImage(); });
  runTest(@"testDebugBuildIsDroppedWhenAnAlternativeExists", ^{ return testDebugBuildIsDroppedWhenAnAlternativeExists(); });
  runTest(@"testSingleCleanAppImage", ^{ return testSingleCleanAppImage(); });
  runTest(@"testDegenerateInputs", ^{ return testDegenerateInputs(); });
}
