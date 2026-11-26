/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWKDEAppImagePicker - picks which file of a download.kde.org application
 * directory is the AppImage to download.
 *
 * A KDE application link names a directory, not a file:
 * https://download.kde.org/stable/digikam/ lists version directories
 * (9.1.0/), and the newest of those lists the builds. One application puts
 * its AppImage straight into the application directory instead
 * (labplot). This is the same separation of concerns as
 * GWAppImageAssetPicker: Foundation only, no network, so the rules can be
 * tested against the real listings recorded in
 * PackageManager/Tests/GWKDEAppImagePickerTests.m.
 *
 * Every rule below was measured against download.kde.org on 2026-09-28, and
 * the comment on each names the real directory it exists for.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* What the picker did, for the caller's error message and for tests. */
typedef NS_ENUM(NSInteger, GWKDEPickOutcome) {
  /* One file was identified. */
  GWKDEPickChosen = 0,
  /* The directory holds AppImages, but none of them is built for this
     machine. Handing the user one for another CPU would give them a file
     that cannot run, so this is a refusal, not a fallback. */
  GWKDEPickNoAppImageForArchitecture,
  /* Nothing here is an AppImage at all (a directory of .dmg, .exe, .deb and
     source tarballs). The caller should try an older version. */
  GWKDEPickNoAppImage,
  /* Several files are equally plausible and guessing would hand the user a
     different program than the one they asked for. */
  GWKDEPickAmbiguous
};

@interface GWKDEAppImagePicker : NSObject

#pragma mark - Choosing the version directory

/* The version directories among these entry names, newest first.
 *
 * The comparison is numeric per component, because the directory names sort
 * as text in exactly the wrong order: plasma's directories include 6.7.5
 * and 6.30, and krita's include 5.3.2 and 5.3.2.1, where "6.30" < "6.7.5"
 * and "5.3.2" < "5.3.2.1" as strings. Entry names that are not versions are
 * left out entirely. */
+ (NSArray<NSString *> *)versionDirectoriesFromEntryNames:
    (NSArray<NSString *> *)entryNames;

/* The newest of those, or nil when the listing has none. */
+ (nullable NSString *)newestVersionDirectoryFromEntryNames:
    (NSArray<NSString *> *)entryNames;

/* Whether a name is one of those version directories: one or more
 * dot-separated runs of digits, optionally a leading "v" (frameworks ships
 * "v5.110.0" alongside "6.7"). Nothing else qualifies, so a suffixed release
 * directory ("24.08.1-rc1") is left out of the walk rather than ordered by a
 * rule nobody has measured, and krita's "FastSketchPlugin-1.0.2" and "updates"
 * are not mistaken for releases. Exposed because the rule is what tells a
 * version directory from a stray subdirectory, and the tests assert it
 * directly. */
+ (BOOL)isVersionDirectoryName:(nullable NSString *)name;

#pragma mark - Choosing the file

/* The AppImage to download out of one directory's file names, for one
 * machine.
 *
 * architecture is what the kernel reports ("x86_64", "aarch64"), and
 * unlike the GitHub picker this is a REQUIREMENT, not a preference: every
 * AppImage on download.kde.org that was measured is x86-64 only, so
 * "pick the closest thing" would hand an aarch64 user a binary their
 * machine cannot execute. When nothing matches, outcome says so and
 * candidates names the files that were on offer.
 *
 * Returns the chosen name, or nil when outcome says why not. */
+ (nullable NSString *)pickFileFromNames:(NSArray<NSString *> *)names
                             appName:(nullable NSString *)appName
                         architecture:(nullable NSString *)architecture
                             outcome:(GWKDEPickOutcome *)outcome
                          candidates:(NSArray<NSString *> *_Nullable *_Nullable)candidates;

#pragma mark - Rules, exposed for the tests

/* These three are the whole rule set, and the subtlest of them (the version
 * ordering) has no other way to be tested directly: through
 * +versionDirectoriesFromEntryNames: it can only be checked as a whole. They
 * are here for the tests, not for callers, and the downloader is the only
 * caller in the tree. */

/* Whether version a is NEWER than version b, comparing components as
 * numbers. A nil or unparseable name is never newer than anything, including
 * another such name. Exposed so the ordering can be asserted pairwise rather
 * than only through a sorted list. */
+ (BOOL)version:(nullable NSString *)a isNewerThan:(nullable NSString *)b;

/* Apply one preference rule, but only when it keeps SOME and not ALL of the
 * candidates: an empty result means the rule was wrong for this directory and
 * an unchanged result means it says nothing, and both are no-ops. The block is
 * handed the lowercased name and answers whether to KEEP it. This is the
 * primitive every preference rule here is written in terms of, and the
 * architecture rule is the one deliberate exception. */
+ (NSArray<NSString *> *)narrow:(NSArray<NSString *> *)candidates
                           keep:(BOOL (^)(NSString *lowerName))keep;

/* The candidates built against the newest Qt toolkit, or nil when the word
 * "Qt" with a number is not what tells them apart. A directory holding
 * digiKam-9.1.0-Qt5-x86-64.appimage and digiKam-9.1.0-Qt6-x86-64.appimage
 * resolves to the Qt6 one; name order would pick Qt5. */
+ (nullable NSArray<NSString *> *)narrowToNewestQtVariant:
    (NSArray<NSString *> *)candidates;

/* The name reduced to what identifies the program, for comparing a file name
 * with the app's own: +[GWAppImageAssetPicker stemForAssetName:] with a
 * trailing toolkit tag dropped, so that "digiKam-9.1.0-Qt6-x86-64.appimage"
 * reduces to "digikam" and not to "digikamqt". An empty or nil name gives an
 * empty string rather than raising. */
+ (NSString *)skeletonForName:(nullable NSString *)name;

@end

NS_ASSUME_NONNULL_END
