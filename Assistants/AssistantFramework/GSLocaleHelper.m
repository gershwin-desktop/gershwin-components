/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSLocaleHelper.h"
#import <X11/Xlib.h>
#import <X11/XKBlib.h>

@implementation GSLocaleHelper

+ (instancetype)sharedHelper
{
    static GSLocaleHelper *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[GSLocaleHelper alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    if (self = [super init]) {
    }
    return self;
}

- (NSString *)detectKeyboardLayout
{
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        return @"us";
    }

    char *layout = getenv("XKBLAYOUT");
    if (layout) {
        XCloseDisplay(display);
        return [NSString stringWithUTF8String:layout];
    }

    XkbDescPtr xkb = XkbGetKeyboard(display, XkbAllComponentsMask, XkbUseCoreKbd);
    if (xkb) {
        if (xkb->names && xkb->names->symbols) {
            const char *symbols = XGetAtomName(display, xkb->names->symbols);
            if (symbols) {
                NSString *symbolsStr = [NSString stringWithUTF8String:symbols];
                NSArray *parts = [symbolsStr componentsSeparatedByString:@"+"];
                if ([parts count] > 0) {
                    XkbFreeKeyboard(xkb, 0, True);
                    XCloseDisplay(display);
                    return parts[0];
                }
            }
        }
        XkbFreeKeyboard(xkb, 0, True);
    }

    XCloseDisplay(display);
    return @"us";
}

- (NSString *)detectLanguageFromKeyboard
{
    NSString *locale = [[NSLocale currentLocale] localeIdentifier];
    if (!locale || [locale length] == 0) {
        return @"en_US.UTF-8";
    }
    if ([locale rangeOfString:@"UTF-8"].location == NSNotFound &&
        [locale rangeOfString:@"utf8"].location == NSNotFound) {
        locale = [locale stringByAppendingString:@".UTF-8"];
    }
    return locale;
}

- (NSArray<NSString *> *)availableLanguages
{
    return @[
        @"English", @"German", @"French", @"Spanish", @"Italian",
        @"Portuguese", @"Russian", @"Dutch", @"Danish", @"Swedish",
        @"Norwegian", @"Finnish", @"Japanese", @"Korean", @"Chinese",
        @"Czech", @"Hungarian", @"Polish", @"Slovak", @"Bulgarian",
        @"Ukrainian", @"Croatian", @"Romanian", @"Slovenian", @"Estonian",
        @"Latvian", @"Lithuanian", @"Icelandic", @"Greek", @"Turkish",
        @"Hebrew", @"Vietnamese", @"Thai"
    ];
}

- (NSArray<NSDictionary *> *)availableKeyboardLayouts
{
    static NSArray<NSDictionary *> *layouts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        layouts = @[
            @{@"code": @"us", @"name": @"US", @"full": @"US English"},
            @{@"code": @"de", @"name": @"German", @"full": @"German"},
            @{@"code": @"fr", @"name": @"French", @"full": @"French"},
            @{@"code": @"es", @"name": @"Spanish", @"full": @"Spanish"},
            @{@"code": @"it", @"name": @"Italian", @"full": @"Italian"},
            @{@"code": @"pt", @"name": @"Portuguese", @"full": @"Portuguese"},
            @{@"code": @"ru", @"name": @"Russian", @"full": @"Russian"},
            @{@"code": @"nl", @"name": @"Dutch", @"full": @"Dutch"},
            @{@"code": @"dk", @"name": @"Danish", @"full": @"Danish"},
            @{@"code": @"se", @"name": @"Swedish", @"full": @"Swedish"},
            @{@"code": @"no", @"name": @"Norwegian", @"full": @"Norwegian"},
            @{@"code": @"fi", @"name": @"Finnish", @"full": @"Finnish"},
            @{@"code": @"jp", @"name": @"Japanese", @"full": @"Japanese"},
            @{@"code": @"kr", @"name": @"Korean", @"full": @"Korean"},
            @{@"code": @"cn", @"name": @"Chinese", @"full": @"Chinese"},
            @{@"code": @"cz", @"name": @"Czech", @"full": @"Czech"},
            @{@"code": @"hu", @"name": @"Hungarian", @"full": @"Hungarian"},
            @{@"code": @"pl", @"name": @"Polish", @"full": @"Polish"},
            @{@"code": @"gb", @"name": @"UK", @"full": @"UK English"},
            @{@"code": @"br", @"name": @"Brazilian", @"full": @"Brazilian"},
            @{@"code": @"ca", @"name": @"Canadian", @"full": @"Canadian"},
            @{@"code": @"tr", @"name": @"Turkish", @"full": @"Turkish"},
            @{@"code": @"il", @"name": @"Hebrew", @"full": @"Hebrew"},
            @{@"code": @"gr", @"name": @"Greek", @"full": @"Greek"}
        ];
    });
    return layouts;
}

- (void)populateLanguageDropdown:(NSPopUpButton *)dropdown
              selectingDetected:(BOOL)selectDetected
{
    [dropdown removeAllItems];
    NSArray *languages = [self availableLanguages];
    [dropdown addItemsWithTitles:languages];

    if (selectDetected) {
        NSString *detected = [self languageNameFromLocale:[self detectLanguageFromKeyboard]];
        if (detected) {
            [dropdown selectItemWithTitle:detected];
        }
    }
}

- (void)populateKeyboardDropdown:(NSPopUpButton *)dropdown
               selectingDetected:(BOOL)selectDetected
{
    [dropdown removeAllItems];
    NSArray<NSDictionary *> *layouts = [self availableKeyboardLayouts];

    for (NSDictionary *layout in layouts) {
        NSString *label = [NSString stringWithFormat:@"%@ (%@)",
                          layout[@"full"], layout[@"code"]];
        [dropdown addItemWithTitle:label];
        [[dropdown lastItem] setRepresentedObject:layout[@"code"]];
    }

    if (selectDetected) {
        NSString *detected = [self detectKeyboardLayout];
        for (NSMenuItem *item in [dropdown itemArray]) {
            NSString *obj = [item representedObject];
            if ([obj isEqualToString:detected]) {
                [dropdown selectItem:item];
                break;
            }
        }
    }
}

- (NSString *)languageCodeFromLocale:(NSString *)locale
{
    if (!locale || [locale length] == 0) return nil;

    NSRange underscore = [locale rangeOfString:@"_"];
    if (underscore.location != NSNotFound) {
        return [locale substringToIndex:underscore.location];
    }
    NSRange dot = [locale rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        return [locale substringToIndex:dot.location];
    }
    return locale;
}

- (NSString *)localeFromLanguageName:(NSString *)languageName
{
    static const char *gsToLocale[][2] = {
        {"English", "en_US.UTF-8"},
        {"German", "de_DE.UTF-8"},
        {"French", "fr_FR.UTF-8"},
        {"Spanish", "es_ES.UTF-8"},
        {"Italian", "it_IT.UTF-8"},
        {"Portuguese", "pt_PT.UTF-8"},
        {"Russian", "ru_RU.UTF-8"},
        {"Dutch", "nl_NL.UTF-8"},
        {"Danish", "da_DK.UTF-8"},
        {"Swedish", "sv_SE.UTF-8"},
        {"Norwegian", "nb_NO.UTF-8"},
        {"Finnish", "fi_FI.UTF-8"},
        {"Japanese", "ja_JP.UTF-8"},
        {"Korean", "ko_KR.UTF-8"},
        {"Chinese", "zh_CN.UTF-8"},
        {"Czech", "cs_CZ.UTF-8"},
        {"Hungarian", "hu_HU.UTF-8"},
        {"Polish", "pl_PL.UTF-8"},
        {"Slovak", "sk_SK.UTF-8"},
        {"Bulgarian", "bg_BG.UTF-8"},
        {"Ukrainian", "uk_UA.UTF-8"},
        {"Croatian", "hr_HR.UTF-8"},
        {"Romanian", "ro_RO.UTF-8"},
        {"Slovenian", "sl_SI.UTF-8"},
        {"Estonian", "et_EE.UTF-8"},
        {"Latvian", "lv_LV.UTF-8"},
        {"Lithuanian", "lt_LT.UTF-8"},
        {"Icelandic", "is_IS.UTF-8"},
        {"Greek", "el_GR.UTF-8"},
        {"Turkish", "tr_TR.UTF-8"},
        {"Hebrew", "he_IL.UTF-8"},
        {"Vietnamese", "vi_VN.UTF-8"},
        {"Thai", "th_TH.UTF-8"},
        {NULL, NULL}
    };

    for (int i = 0; gsToLocale[i][0]; i++) {
        if ([languageName isEqualToString:[NSString stringWithUTF8String:gsToLocale[i][0]]]) {
            return [NSString stringWithUTF8String:gsToLocale[i][1]];
        }
    }
    return nil;
}

- (NSString *)languageNameFromLocale:(NSString *)locale
{
    static const char *langMap[][2] = {
        {"de", "German"},
        {"fr", "French"},
        {"es", "Spanish"},
        {"it", "Italian"},
        {"pt", "Portuguese"},
        {"ru", "Russian"},
        {"nl", "Dutch"},
        {"tr", "Turkish"},
        {"il", "Hebrew"},
        {"dk", "Danish"},
        {"se", "Swedish"},
        {"no", "Norwegian"},
        {"fi", "Finnish"},
        {"jp", "Japanese"},
        {"kr", "Korean"},
        {"cn", "Chinese"},
        {"cz", "Czech"},
        {"hu", "Hungarian"},
        {"pl", "Polish"},
        {"sk", "Slovak"},
        {"bg", "Bulgarian"},
        {"ua", "Ukrainian"},
        {"hr", "Croatian"},
        {"ro", "Romanian"},
        {"si", "Slovenian"},
        {"ee", "Estonian"},
        {"lv", "Latvian"},
        {"lt", "Lithuanian"},
        {"is", "Icelandic"},
        {"gr", "Greek"},
        {"vn", "Vietnamese"},
        {"th", "Thai"},
        {"by", "Belarusian"},
        {"mk", "Macedonian"},
        {"mt", "Maltese"},
        {"ca", "French"},
        {"gb", "English"},
        {"us", "English"},
        {"br", "Portuguese"},
        {NULL, NULL}
    };

    NSString *langCode = [self languageCodeFromLocale:locale];
    if (!langCode || [langCode length] < 2) return nil;

    for (int i = 0; langMap[i][0]; i++) {
        if ([langCode isEqualToString:[NSString stringWithUTF8String:langMap[i][0]]]) {
            return [NSString stringWithUTF8String:langMap[i][1]];
        }
    }
    return nil;
}

- (void)applyLanguage:(NSString *)languageName
{
    NSString *localeStr = [self localeFromLanguageName:languageName];
    if (!localeStr) return;

    [[NSUserDefaults standardUserDefaults] setObject:@[languageName, @"English"] forKey:@"Languages"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applyKeyboardLayout:(NSString *)layoutCode
{
    setenv("XKBLAYOUT", [layoutCode UTF8String], 1);

    NSString *home = NSHomeDirectory();
    NSString *xorgConf = [home stringByAppendingPathComponent:@".xorg.conf"];
    NSError *error = nil;
    NSMutableString *content = [NSMutableString string];

    if ([[NSFileManager defaultManager] fileExistsAtPath:xorgConf]) {
        NSString *existing = [NSString stringWithContentsOfFile:xorgConf
                                                       encoding:NSUTF8StringEncoding
                                                          error:&error];
        if (existing) {
            [content appendString:existing];
        }
    }

    if ([content rangeOfString:@"Option \"XkbLayout\""].location == NSNotFound) {
        [content appendFormat:@"\nSection \"InputClass\"\n"
                           @"Identifier \"keyboardDefaults\"\n"
                           @"MatchIsKeyboard \"on\"\n"
                           @"Option \"XkbLayout\" \"%@\"\n"
                           @"EndSection\n", layoutCode];

        [content writeToFile:xorgConf
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:&error];
    }
}

@end
