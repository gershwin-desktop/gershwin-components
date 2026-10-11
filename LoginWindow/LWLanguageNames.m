/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LWLanguageNames.h"

NSString *LWLanguageNameForLocale(NSString *locale)
{
    /* Keyed by ISO 639-1 language codes, because a locale starts with the
     * language ("ja_JP"), not with the keyboard layout code ("jp") that
     * the locale may have been inferred from. */
    static const char *langMap[][2] = {
        {"en", "English"},   {"de", "German"},     {"fr", "French"},
        {"es", "Spanish"},   {"it", "Italian"},    {"pt", "Portuguese"},
        {"ru", "Russian"},   {"nl", "Dutch"},      {"tr", "Turkish"},
        {"he", "Hebrew"},    {"da", "Danish"},     {"sv", "Swedish"},
        {"nb", "Norwegian"}, {"nn", "Norwegian"},  {"no", "Norwegian"},
        {"fi", "Finnish"},   {"ja", "Japanese"},   {"ko", "Korean"},
        {"zh", "Chinese"},   {"cs", "Czech"},      {"hu", "Hungarian"},
        {"pl", "Polish"},    {"sk", "Slovak"},     {"bg", "Bulgarian"},
        {"uk", "Ukrainian"}, {"hr", "Croatian"},   {"ro", "Romanian"},
        {"sl", "Slovenian"}, {"et", "Estonian"},   {"lv", "Latvian"},
        {"lt", "Lithuanian"},{"is", "Icelandic"},  {"el", "Greek"},
        {"vi", "Vietnamese"},{"th", "Thai"},       {"be", "Belarusian"},
        {"mk", "Macedonian"},{"mt", "Maltese"},
        {NULL, NULL}
    };

    if ([locale length] == 0) {
        return nil;
    }
    NSRange cut = [locale rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"_.@"]];
    NSString *langCode = (cut.location == NSNotFound)
        ? locale : [locale substringToIndex:cut.location];
    const char *code = [langCode UTF8String];

    for (int i = 0; langMap[i][0]; i++) {
        if (strcmp(code, langMap[i][0]) == 0) {
            return [NSString stringWithUTF8String:langMap[i][1]];
        }
    }
    return nil;
}
