/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../LWLanguageNames.m"

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];

    /* KeyboardManager turns the layouts jp/kr/cn into these locales; the
     * dropdown has to find the language name for each of them. */
    PASS_EQUAL(LWLanguageNameForLocale(@"ja_JP.UTF-8"), @"Japanese",
               "ja_JP.UTF-8 maps to Japanese");
    PASS_EQUAL(LWLanguageNameForLocale(@"ko_KR.UTF-8"), @"Korean",
               "ko_KR.UTF-8 maps to Korean");
    PASS_EQUAL(LWLanguageNameForLocale(@"zh_CN.UTF-8"), @"Chinese",
               "zh_CN.UTF-8 maps to Chinese");
    PASS_EQUAL(LWLanguageNameForLocale(@"zh_TW.UTF-8"), @"Chinese",
               "zh_TW.UTF-8 maps to Chinese");

    /* Other layouts whose code differs from the language code. */
    PASS_EQUAL(LWLanguageNameForLocale(@"da_DK.UTF-8"), @"Danish",
               "da_DK.UTF-8 maps to Danish");
    PASS_EQUAL(LWLanguageNameForLocale(@"cs_CZ.UTF-8"), @"Czech",
               "cs_CZ.UTF-8 maps to Czech");
    PASS_EQUAL(LWLanguageNameForLocale(@"el_GR.UTF-8"), @"Greek",
               "el_GR.UTF-8 maps to Greek");
    PASS_EQUAL(LWLanguageNameForLocale(@"en_GB.UTF-8"), @"English",
               "en_GB.UTF-8 maps to English");
    PASS_EQUAL(LWLanguageNameForLocale(@"fr_CA.UTF-8"), @"French",
               "fr_CA.UTF-8 maps to French");

    /* Locales without region or encoding still carry the language. */
    PASS_EQUAL(LWLanguageNameForLocale(@"de"), @"German",
               "bare language code maps");
    PASS_EQUAL(LWLanguageNameForLocale(@"de.UTF-8"), @"German",
               "language code with encoding maps");

    /* Keyboard layout codes are not language codes. */
    PASS(LWLanguageNameForLocale(@"jp_JP.UTF-8") == nil,
         "layout code jp is not a language");
    PASS(LWLanguageNameForLocale(@"C") == nil, "C locale has no language");
    PASS(LWLanguageNameForLocale(@"") == nil, "empty locale has no language");
    PASS(LWLanguageNameForLocale(nil) == nil, "nil locale has no language");

    [arp release];
    return 0;
}
