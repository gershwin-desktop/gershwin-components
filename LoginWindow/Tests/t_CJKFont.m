/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../LWCJKFont.m"

static NSString * const kNoFonts = @"";
static NSString * const kSarasaListed =
    @"/System/Library/Fonts/Sarasa/SarasaUiJ-Regular.ttf: Sarasa UI J:style=Regular\n";

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    LWCJKFontDecision d;
    NSDictionary *a;

    /* Each language gets the archive for its own orthography. */
    a = LWCJKFontAssetForLocale(@"ja_JP.UTF-8", kNoFonts, @"Linux", &d);
    PASS(d == LWCJKFontDownload, "ja_JP without a Japanese font downloads");
    PASS_EQUAL([a objectForKey:LWCJKFontArchiveKey],
               @"SarasaUiJ-TTF-Unhinted-1.0.42.7z", "ja uses SarasaUiJ");
    PASS_EQUAL([a objectForKey:LWCJKFontURLKey],
               @"https://github.com/be5invis/Sarasa-Gothic/releases/download/v1.0.42/SarasaUiJ-TTF-Unhinted-1.0.42.7z",
               "ja URL points at the pinned release over https");
    PASS_EQUAL([a objectForKey:LWCJKFontSHA256Key],
               @"53c9bebc7be6f80e7493e235574ce58ecacf3c944e2555dabe5f80487db78b2a",
               "ja digest is pinned");
    NSArray *jaMembers = [NSArray arrayWithObjects:
        @"SarasaUiJ-Regular.ttf", @"SarasaUiJ-Bold.ttf", nil];
    PASS_EQUAL([a objectForKey:LWCJKFontMembersKey], jaMembers,
               "only Regular and Bold are extracted");
    PASS_EQUAL(LWCJKFontLanguageForLocale(@"ja_JP.UTF-8"), @"ja",
               "ja_JP is checked with fc-list :lang=ja");

    a = LWCJKFontAssetForLocale(@"ko_KR.UTF-8", kNoFonts, @"FreeBSD", &d);
    PASS(d == LWCJKFontDownload, "ko_KR without a Korean font downloads");
    PASS_EQUAL([a objectForKey:LWCJKFontArchiveKey],
               @"SarasaUiK-TTF-Unhinted-1.0.42.7z", "ko uses SarasaUiK");
    PASS_EQUAL([a objectForKey:LWCJKFontSHA256Key],
               @"8af59abc229b11f53e7a87cf521ba7c479382728c1abc2d8e1c7f56267c1172d",
               "ko digest is pinned");
    PASS_EQUAL(LWCJKFontLanguageForLocale(@"ko_KR.UTF-8"), @"ko",
               "ko_KR is checked with fc-list :lang=ko");

    a = LWCJKFontAssetForLocale(@"zh_CN.UTF-8", kNoFonts, @"NextBSD", &d);
    PASS(d == LWCJKFontDownload, "zh_CN without a Chinese font downloads");
    PASS_EQUAL([a objectForKey:LWCJKFontArchiveKey],
               @"SarasaUiSC-TTF-Unhinted-1.0.42.7z", "zh_CN uses SarasaUiSC");
    PASS_EQUAL([a objectForKey:LWCJKFontSHA256Key],
               @"5b7fe38c8eb9a8438544c8a8a64ca209731390dc9b3c62156bea7725c932524b",
               "zh_CN digest is pinned");
    PASS_EQUAL(LWCJKFontLanguageForLocale(@"zh_CN.UTF-8"), @"zh-cn",
               "zh_CN is checked with fc-list :lang=zh-cn");

    a = LWCJKFontAssetForLocale(@"zh_TW.UTF-8", kNoFonts, @"Linux", &d);
    PASS(d == LWCJKFontDownload, "zh_TW without a Chinese font downloads");
    PASS_EQUAL([a objectForKey:LWCJKFontArchiveKey],
               @"SarasaUiTC-TTF-Unhinted-1.0.42.7z", "zh_TW uses SarasaUiTC");
    PASS_EQUAL([a objectForKey:LWCJKFontSHA256Key],
               @"8d072fdee7fda93505d23f9ec92cb28b12bbdeb41e8c0c809029d165c928bec2",
               "zh_TW digest is pinned");
    PASS_EQUAL(LWCJKFontLanguageForLocale(@"zh_TW.UTF-8"), @"zh-tw",
               "zh_TW is checked with fc-list :lang=zh-tw");

    a = LWCJKFontAssetForLocale(@"zh_HK.UTF-8", kNoFonts, @"Linux", &d);
    PASS(d == LWCJKFontDownload, "zh_HK without a Chinese font downloads");
    PASS_EQUAL([a objectForKey:LWCJKFontArchiveKey],
               @"SarasaUiHC-TTF-Unhinted-1.0.42.7z", "zh_HK uses SarasaUiHC");
    PASS_EQUAL([a objectForKey:LWCJKFontSHA256Key],
               @"60af17f050e2bbd9ba082eeee86866f9ca9a7191bdc156eb9b67f749ad6c5441",
               "zh_HK digest is pinned");
    PASS_EQUAL(LWCJKFontLanguageForLocale(@"zh_HK.UTF-8"), @"zh-hk",
               "zh_HK is checked with fc-list :lang=zh-hk");

    /* Non-CJK locales never download, whatever fontconfig says. */
    a = LWCJKFontAssetForLocale(@"de_DE.UTF-8", kNoFonts, @"Linux", &d);
    PASS(a == nil && d == LWCJKFontNotCJK, "de_DE needs no CJK font");
    a = LWCJKFontAssetForLocale(@"jam_JM.UTF-8", kNoFonts, @"Linux", &d);
    PASS(a == nil && d == LWCJKFontNotCJK, "jam is not ja");
    a = LWCJKFontAssetForLocale(nil, kNoFonts, @"Linux", &d);
    PASS(a == nil && d == LWCJKFontNotCJK, "no locale needs no CJK font");
    PASS(LWCJKFontLanguageForLocale(@"en_US.UTF-8") == nil,
         "en_US has no CJK fontconfig tag");

    /* A font already present, such as the one an earlier login installed,
     * means nothing is downloaded again. */
    a = LWCJKFontAssetForLocale(@"ja_JP.UTF-8", kSarasaListed, @"Linux", &d);
    PASS(a == nil && d == LWCJKFontAlreadyCovered,
         "ja_JP with a Japanese font already listed does not download");
    a = LWCJKFontAssetForLocale(@"ja_JP.UTF-8", @"\n", @"Linux", &d);
    PASS(d == LWCJKFontDownload, "a blank fc-list line is not coverage");

    /* No bsdtar on OpenBSD: refused rather than attempted. */
    a = LWCJKFontAssetForLocale(@"ja_JP.UTF-8", kNoFonts, @"OpenBSD", &d);
    PASS(a == nil && d == LWCJKFontUnsupportedOS, "OpenBSD is not supported");
    a = LWCJKFontAssetForLocale(@"ja_JP.UTF-8", kSarasaListed, @"OpenBSD", &d);
    PASS(a == nil && d == LWCJKFontAlreadyCovered,
         "OpenBSD with a font present is not an error");

    [arp release];
    return 0;
}
