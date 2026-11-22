/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_LanguageGuess - which language to suggest for a page. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCLanguageGuess.h"

static NSArray *
Words(NSString *text)
{
  return [text componentsSeparatedByString: @" "];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *german = @"Die Erläuterung der Übersicht ist für alle Mitarbeiter "
    @"gedacht, die sich mit dem neuen Verfahren vertraut machen wollen. Es "
    @"ist nicht schwer, und die Schritte sind auf der nächsten Seite in der "
    @"richtigen Reihenfolge von oben nach unten beschrieben.";
  NSString *french = @"Ceci est un texte en français pour tester la "
    @"reconnaissance de la langue. Les pages que nous numérisons sont dans "
    @"un classeur et nous voulons les retrouver plus tard dans le dossier "
    @"des archives pour la comptabilité.";
  NSString *frenchAsReadInEnglish = @"Ceci est un texte en francais pour "
    @"tester la reconnaissance de la langue. Les pages que nous numerisons "
    @"sont dans un classeur et nous voulons les retrouver plus tard dans le "
    @"dossier des archives pour la comptabilite.";
  NSString *english = @"This is the report that the team prepared for the "
    @"board. It is based on the numbers of the last quarter and it shows "
    @"that the sales in the north are better than in the south, which was "
    @"not expected by anyone on the team.";

  PASS_EQUAL(SCGuessLanguageFromWords(Words(german)), @"deu", "German text");
  PASS_EQUAL(SCGuessLanguageFromWords(Words(french)), @"fra", "French text");
  PASS_EQUAL(SCGuessLanguageFromWords(Words(frenchAsReadInEnglish)), @"fra",
             "French read without accents is still French");
  PASS_EQUAL(SCGuessLanguageFromWords(Words(english)), @"eng", "English text");
  PASS(SCGuessLanguageFromWords(Words(@"Rechnung Nr. 4711 Betrag 12,50 EUR")) == nil,
       "a few words are not enough to guess");
  PASS(SCGuessLanguageFromWords(Words(
         @"Lorem ipsum dolor sit amet consectetur adipiscing elit sed do "
         @"eiusmod tempor incididunt ut labore et dolore magna aliqua Ut "
         @"enim ad minim veniam quis nostrud exercitation ullamco laboris "
         @"nisi ut aliquip ex ea commodo consequat")) == nil,
       "text in no listed language guesses nothing");

  PASS_EQUAL(SCLanguageForScript(@"Cyrillic"), @"rus", "Cyrillic suggests Russian");
  PASS_EQUAL(SCLanguageForScript(@"HanT"), @"chi_tra", "traditional Han");
  PASS(SCLanguageForScript(@"Latin") == nil, "Latin is left to the word count");
  PASS_EQUAL(SCScriptForLanguage(@"ukr"), @"Cyrillic",
             "Ukrainian covers Cyrillic pages too");
  PASS_EQUAL(SCScriptForLanguage(@"deu"), @"Latin", "German is Latin script");

  [arp release];
  return 0;
}
