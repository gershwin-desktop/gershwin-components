/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWCJKFont.h"

NSString * const LWCJKFontArchiveKey = @"Archive";
NSString * const LWCJKFontURLKey = @"URL";
NSString * const LWCJKFontSHA256Key = @"SHA256";
NSString * const LWCJKFontMembersKey = @"Members";
NSString * const LWCJKFontInstallDirectory = @"/System/Library/Fonts/Sarasa";

/* Sarasa Gothic (SIL OFL 1.1), https://github.com/be5invis/Sarasa-Gothic.
 * Pinned to one release with the sha256 digests GitHub publishes for its
 * assets, so a changed or tampered archive is refused. Each archive covers
 * only its own orthography (SarasaUiSC has no Japanese or Korean glyph
 * variants), hence one archive per language. */
#define LW_SARASA_VERSION "1.0.42"

static const struct {
    const char *prefix;    /* locale prefix; first match wins, so plain "zh" is last */
    const char *fcLang;    /* fontconfig language tag */
    const char *family;    /* Sarasa subfamily file name stem */
    const char *sha256;
} sarasaAssets[] = {
    { "ja",    "ja",    "SarasaUiJ",
      "53c9bebc7be6f80e7493e235574ce58ecacf3c944e2555dabe5f80487db78b2a" },
    { "ko",    "ko",    "SarasaUiK",
      "8af59abc229b11f53e7a87cf521ba7c479382728c1abc2d8e1c7f56267c1172d" },
    { "zh_TW", "zh-tw", "SarasaUiTC",
      "8d072fdee7fda93505d23f9ec92cb28b12bbdeb41e8c0c809029d165c928bec2" },
    { "zh_HK", "zh-hk", "SarasaUiHC",
      "60af17f050e2bbd9ba082eeee86866f9ca9a7191bdc156eb9b67f749ad6c5441" },
    { "zh_MO", "zh-hk", "SarasaUiHC",
      "60af17f050e2bbd9ba082eeee86866f9ca9a7191bdc156eb9b67f749ad6c5441" },
    { "zh",    "zh-cn", "SarasaUiSC",
      "5b7fe38c8eb9a8438544c8a8a64ca209731390dc9b3c62156bea7725c932524b" },
    { NULL, NULL, NULL, NULL }
};

static int assetIndexForLocale(NSString *locale)
{
    if ([locale length] == 0) {
        return -1;
    }
    const char *loc = [locale UTF8String];
    for (int i = 0; sarasaAssets[i].prefix; i++) {
        size_t len = strlen(sarasaAssets[i].prefix);
        /* "ja" must not match "jam" (Jamaican Creole): the prefix has to end
         * where the language or territory part of the locale ends. */
        char next = loc[len];
        if (strncmp(loc, sarasaAssets[i].prefix, len) == 0
            && (next == '\0' || next == '_' || next == '.' || next == '@')) {
            return i;
        }
    }
    return -1;
}

NSString *LWCJKFontLanguageForLocale(NSString *locale)
{
    int i = assetIndexForLocale(locale);
    return (i < 0) ? nil : [NSString stringWithUTF8String:sarasaAssets[i].fcLang];
}

NSDictionary *LWCJKFontAssetForLocale(NSString *locale,
                                      NSString *fcListOutput,
                                      NSString *osName,
                                      LWCJKFontDecision *decision)
{
    LWCJKFontDecision dummy;
    if (!decision) {
        decision = &dummy;
    }

    int i = assetIndexForLocale(locale);
    if (i < 0) {
        *decision = LWCJKFontNotCJK;
        return nil;
    }

    /* Any font fontconfig reports for the language is enough: a re-login,
     * or a font the user installed, must not trigger a 50 MB download. */
    NSString *listed = [fcListOutput stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([listed length] > 0) {
        *decision = LWCJKFontAlreadyCovered;
        return nil;
    }

    /* The archives are 7z; OpenBSD has no libarchive bsdtar in base. */
    if ([osName length] == 0 || [osName isEqualToString:@"OpenBSD"]) {
        *decision = LWCJKFontUnsupportedOS;
        return nil;
    }

    NSString *family = [NSString stringWithUTF8String:sarasaAssets[i].family];
    NSString *archive = [NSString stringWithFormat:@"%@-TTF-Unhinted-%s.7z",
        family, LW_SARASA_VERSION];
    NSString *url = [NSString stringWithFormat:
        @"https://github.com/be5invis/Sarasa-Gothic/releases/download/v%s/%@",
        LW_SARASA_VERSION, archive];
    /* Regular and Bold are all the desktop draws; the other eight weights
     * would add about 110 MB. */
    NSArray *members = [NSArray arrayWithObjects:
        [family stringByAppendingString:@"-Regular.ttf"],
        [family stringByAppendingString:@"-Bold.ttf"], nil];

    *decision = LWCJKFontDownload;
    return [NSDictionary dictionaryWithObjectsAndKeys:
        archive, LWCJKFontArchiveKey,
        url, LWCJKFontURLKey,
        [NSString stringWithUTF8String:sarasaAssets[i].sha256], LWCJKFontSHA256Key,
        members, LWCJKFontMembersKey,
        nil];
}
