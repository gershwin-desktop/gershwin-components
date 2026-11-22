/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Guesses which text recognition language a page needs, to suggest
 * installing it. tesseract can only tell the script (Latin, Cyrillic, ...),
 * so within the Latin script the language is guessed from its most common
 * words. All results are tesseract language codes ("fra", "rus").
 */

/* The usual language for a script tesseract reports; nil for Latin and unknown */
NSString *SCLanguageForScript(NSString *script);

/* The script a language is written in ("Cyrillic" for "ukr"), "Latin" by default */
NSString *SCScriptForLanguage(NSString *code);

/*
 * The language most of these words belong to, when the text is long enough
 * and one language clearly wins; nil otherwise
 */
NSString *SCGuessLanguageFromWords(NSArray *words);
