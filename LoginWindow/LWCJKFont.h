/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

typedef enum {
    LWCJKFontNotCJK,          /* the locale needs no CJK font */
    LWCJKFontAlreadyCovered,  /* fontconfig already has a font for it */
    LWCJKFontUnsupportedOS,   /* no way to unpack the archive here */
    LWCJKFontDownload         /* fetch the returned asset */
} LWCJKFontDecision;

/* Keys of the asset dictionary returned by LWCJKFontAssetForLocale(). */
extern NSString * const LWCJKFontArchiveKey;  /* "SarasaUiJ-TTF-Unhinted-1.0.42.7z" */
extern NSString * const LWCJKFontURLKey;      /* https download URL */
extern NSString * const LWCJKFontSHA256Key;   /* lowercase hex digest of the archive */
extern NSString * const LWCJKFontMembersKey;  /* NSArray of the .ttf files to extract */

/* Where the fonts and their license end up; fontconfig scans
 * /System/Library/Fonts recursively, so no configuration change is needed. */
extern NSString * const LWCJKFontInstallDirectory;

/* fontconfig language tag ("ja", "ko", "zh-cn", "zh-tw", "zh-hk") for a
 * POSIX locale, or nil when the locale is not Chinese, Japanese or Korean. */
NSString *LWCJKFontLanguageForLocale(NSString *locale);

/* Decides whether a CJK font has to be downloaded for the locale.
 * fcListOutput is the output of "fc-list :lang=<tag>" for the tag above,
 * osName the uname(3) sysname. Returns the asset for LWCJKFontDownload,
 * nil otherwise; *decision (may be NULL) says why. */
NSDictionary *LWCJKFontAssetForLocale(NSString *locale,
                                      NSString *fcListOutput,
                                      NSString *osName,
                                      LWCJKFontDecision *decision);
