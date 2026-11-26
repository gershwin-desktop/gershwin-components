/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCLanguageGuess.h"

/* Fewer recognized words than this say too little about the language */
static const NSUInteger SCMinimumWords = 25;

static NSDictionary *
SCScriptLanguages(void)
{
  static NSDictionary *map;

  if (map == nil)
    {
      /* Names as tesseract's script detection reports them */
      map = @{
        @"Cyrillic": @"rus", @"Greek": @"ell", @"Arabic": @"ara",
        @"Hebrew": @"heb", @"Han": @"chi_sim", @"HanS": @"chi_sim",
        @"HanT": @"chi_tra", @"Hangul": @"kor", @"Japanese": @"jpn",
        @"Katakana": @"jpn", @"Hiragana": @"jpn", @"Devanagari": @"hin",
        @"Thai": @"tha", @"Armenian": @"hye", @"Georgian": @"kat",
        @"Bengali": @"ben", @"Tamil": @"tam", @"Telugu": @"tel",
        @"Kannada": @"kan", @"Malayalam": @"mal", @"Gujarati": @"guj",
        @"Gurmukhi": @"pan", @"Ethiopic": @"amh", @"Khmer": @"khm",
        @"Lao": @"lao", @"Myanmar": @"mya", @"Sinhala": @"sin",
        @"Tibetan": @"bod", @"Syriac": @"syr", @"Thaana": @"div",
      };
    }
  return map;
}

NSString *
SCLanguageForScript(NSString *script)
{
  return [SCScriptLanguages() objectForKey: script];
}

NSString *
SCScriptForLanguage(NSString *code)
{
  /* Languages sharing a script with the one the map names for it */
  NSDictionary *more = @{
    @"ukr": @"Cyrillic", @"bel": @"Cyrillic", @"bul": @"Cyrillic",
    @"mkd": @"Cyrillic", @"srp": @"Cyrillic", @"kaz": @"Cyrillic",
    @"fas": @"Arabic", @"urd": @"Arabic", @"yid": @"Hebrew",
    @"mar": @"Devanagari", @"nep": @"Devanagari", @"san": @"Devanagari",
  };
  NSString *script = [more objectForKey: code];

  if (script != nil)
    {
      return script;
    }
  for (NSString *s in SCScriptLanguages())
    {
      if ([[SCScriptLanguages() objectForKey: s] isEqualToString: code])
        {
          return s;
        }
    }
  return @"Latin";
}

/*
 * Frequent short words of each language, without accents: recognition with
 * the wrong language often loses them. Single letters are left out, they
 * are words in too many languages.
 */
static NSDictionary *
SCCommonWords(void)
{
  static NSDictionary *words;

  if (words == nil)
    {
      words = @{
        @"eng": @"the and of to in is that for it with as was on are this be by not",
        @"deu": @"der die und das ist nicht ein eine den dem zu mit sich auf fur von im",
        @"fra": @"le la les et des un une est dans pour que qui pas sur au du ce",
        @"spa": @"el la los las de que en un una es por con para del se lo",
        @"ita": @"il la di che un una per non sono con del della nel gli le",
        @"por": @"os as de que um uma para com nao do da em no na se",
        @"nld": @"de het een en van is dat niet op te met zijn voor",
        @"swe": @"och att det som en ar pa for med av inte den till",
        @"dan": @"og at det som en er pa for med af ikke den til",
        @"fin": @"ja on ei se etta oli han mutta kuin tai",
        @"pol": @"nie na ze sie to jest do jak po od",
        @"ces": @"je se na ze to do jako by po od",
        @"hun": @"az es hogy nem egy is van meg",
        @"ron": @"si de la in un cu pe nu ca sunt",
        @"tur": @"ve bir bu da de icin ile ne",
        @"cat": @"el la els les de que en un una es per amb",
        @"hrv": @"je na da se su za od kao",
        @"ind": @"dan yang di ini itu dengan untuk dari tidak",
      };
    }
  return words;
}

/* Lower case without accents, so "Für" matches "fur" */
static NSString *
SCFold(NSString *word)
{
  NSMutableString *out = [NSMutableString string];
  NSString *d = [[word lowercaseString] decomposedStringWithCanonicalMapping];
  NSCharacterSet *letters = [NSCharacterSet lowercaseLetterCharacterSet];
  NSUInteger i;

  for (i = 0; i < [d length]; i++)
    {
      unichar c = [d characterAtIndex: i];

      if ([letters characterIsMember: c])
        {
          [out appendFormat: @"%C", c];
        }
    }
  return out;
}

NSString *
SCGuessLanguageFromWords(NSArray *words)
{
  NSMutableDictionary *sets = [NSMutableDictionary dictionary];
  NSMutableDictionary *hits = [NSMutableDictionary dictionary];
  NSString *best = nil;
  NSUInteger total = 0, bestHits = 0, secondHits = 0;

  NSCountedSet *shared = [NSCountedSet set];

  for (NSString *code in SCCommonWords())
    {
      NSSet *set = [NSSet setWithArray:
        [[SCCommonWords() objectForKey: code] componentsSeparatedByString: @" "]];

      [sets setObject: set forKey: code];
      [shared addObjectsFromArray: [set allObjects]];
    }
  for (NSString *raw in words)
    {
      NSString *w = SCFold(raw);

      if ([w length] == 0)
        {
          continue;
        }
      total++;
      /* "la", "de", "en" are common in half a dozen languages and tell nothing */
      if ([shared countForObject: w] != 1)
        {
          continue;
        }
      for (NSString *code in sets)
        {
          if ([[sets objectForKey: code] containsObject: w])
            {
              [hits setObject: @([[hits objectForKey: code] unsignedIntegerValue] + 1)
                       forKey: code];
            }
        }
    }
  if (total < SCMinimumWords)
    {
      return nil;
    }
  for (NSString *code in hits)
    {
      NSUInteger n = [[hits objectForKey: code] unsignedIntegerValue];

      if (n > bestHits)
        {
          secondHits = bestHits;
          bestHits = n;
          best = code;
        }
      else if (n > secondHits)
        {
          secondHits = n;
        }
    }
  /*
   * Function words make up a good part of any text; a language that wins
   * clearly is the language, close calls (Danish, Norwegian) are not guessed
   */
  if (bestHits * 100 < total * 8 || bestHits < 2 * secondHits)
    {
      return nil;
    }
  return best;
}
