/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageAssetPicker - picks which file of a GitHub release is the
 * AppImage to download.
 *
 * This is a transliteration of the catalog's own rules (the
 * appimage.github.io project resolves every entry with the same code its
 * CI uses, in code/find-appimage.sh), so that AppGarden and the catalog
 * agree on what "the AppImage of this release" means.
 *
 * Foundation only, no network: the caller fetches the release's asset
 * names and asks which one to take. That is what makes the rules testable
 * against the real, awkward releases recorded in PackageManagerTest.m.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* What the picker did, for the caller's error message and for tests. */
typedef NS_ENUM(NSInteger, GWAppImagePickOutcome) {
  /* One asset was identified. */
  GWAppImagePickChosen = 0,
  /* No asset in the release ends in .AppImage (a mobile-only or
     source-only release, say). The caller should look at an older
     release. */
  GWAppImagePickNoAppImage,
  /* The release holds AppImages but they cannot be told apart, and
     guessing would hand the user a file that may be a different program
     or a different CPU. */
  GWAppImagePickAmbiguous
};

@interface GWAppImageAssetPicker : NSObject

/* The AppImage to download out of one release's assets.
 *
 * names are the asset file names in the order the forge listed them, which
 * for a release with several architectures is not the order that helps.
 * appName is the catalog's name for the application, used to pick the right
 * file when a release ships several different programs; pass nil when only
 * one is in play.
 *
 * Returns the chosen name, or nil when outcome says why not. On a nil
 * result, candidates (when given) is filled with the names it could not
 * tell apart, so the caller can name them in the error. */
+ (nullable NSString *)pickAssetFromNames:(NSArray<NSString *> *)names
                                  appName:(nullable NSString *)appName
                                  outcome:(GWAppImagePickOutcome *)outcome
                               candidates:(NSArray<NSString *> *_Nullable *_Nullable)candidates;

/* The name reduced to a comparable skeleton: no extension, no version, no
 * architecture, no git hash, no punctuation, lowercased. "Krita" and
 * "krita-5.2.6-x86_64.AppImage" both reduce to "krita", which is how a
 * release that ships several applications is told apart. Exposed because it
 * is the subtlest rule here and the tests assert it directly. A nil name
 * gives an empty string rather than raising, since the framework hands this
 * whatever a release happens to list. */
+ (NSString *)stemForAssetName:(nullable NSString *)name;

@end

NS_ASSUME_NONNULL_END
