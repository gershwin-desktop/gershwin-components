/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GSLocaleHelper : NSObject

+ (instancetype)sharedHelper;

- (NSString *)detectLanguageFromKeyboard;
- (NSString *)detectKeyboardLayout;
- (NSArray<NSString *> *)availableLanguages;
- (NSArray<NSDictionary *> *)availableKeyboardLayouts;

- (void)populateLanguageDropdown:(NSPopUpButton *)dropdown
              selectingDetected:(BOOL)selectDetected;
- (void)populateKeyboardDropdown:(NSPopUpButton *)dropdown
               selectingDetected:(BOOL)selectDetected;

- (nullable NSString *)languageCodeFromLocale:(NSString *)locale;
- (nullable NSString *)localeFromLanguageName:(NSString *)languageName;
- (nullable NSString *)languageNameFromLocale:(NSString *)locale;

- (void)applyLanguage:(NSString *)languageName;
- (void)applyKeyboardLayout:(NSString *)layoutCode;

@end

NS_ASSUME_NONNULL_END
