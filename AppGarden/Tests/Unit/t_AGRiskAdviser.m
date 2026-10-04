/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "AGApp.h"
#import "AGCatalog.h"
#import "AGFeedParser.h"
#import "AGRiskAdviser.h"
#import "AGRiskCategory.h"
#import "AGRiskMatch.h"

/* The shipped file, not a copy: the warnings a user reads are these words, so
 * a broken or half-written entry has to fail here rather than in the panel. */
static NSString *const riskCategoriesPath = @"../../Resources/RiskCategories.plist";

static id LoadRiskPropertyList(void)
{
  NSData *data = [NSData dataWithContentsOfFile:riskCategoriesPath];
  PASS(data != nil, "Resources/RiskCategories.plist is readable");
  if (data == nil)
    return nil;
  id plist = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:NULL];
  PASS(plist != nil, "the risk file parses as a property list");
  return plist;
}

static AGRiskAdviser *LoadedAdviser(void)
{
  return [AGRiskAdviser adviserWithPropertyList:LoadRiskPropertyList()];
}

static AGApp *App(NSString *name, NSString *descriptionText)
{
  NSMutableDictionary *item = [NSMutableDictionary dictionary];
  [item setObject:(name != nil ? name : @"Thing") forKey:@"name"];
  if (descriptionText != nil)
    [item setObject:descriptionText forKey:@"description"];
  return [[[AGApp alloc] initWithFeedItem:item] retain];
}

/* A message passed to PASS or PASS_EQUAL is a plain C string, not an @"...":
 * the macro puts it after a "%s:%d ... " literal, and the two only join if
 * both are C strings. Everything else here is an ordinary expression. */

/* How many categories one item falls into. */
static NSUInteger MatchesOf(NSString *name, NSString *descriptionText)
{
  return [[LoadedAdviser() matchesForApp:App(name, descriptionText)] count];
}

/* The identifier of the one category that matched, or nil. A panel with two
 * categories is a different code path, so the tests ask the narrow question. */
static NSString *OnlyCategoryMatchedBy(NSString *name, NSString *descriptionText)
{
  NSArray<AGRiskMatch *> *matches = [LoadedAdviser() matchesForApp:App(name, descriptionText)];
  if ([matches count] != 1)
    return nil;
  return [[matches objectAtIndex:0].category identifier];
}

/* The keywords that fired, when exactly one category did. */
static NSArray<NSString *> *KeywordsMatchedBy(NSString *name, NSString *descriptionText)
{
  NSArray<AGRiskMatch *> *matches = [LoadedAdviser() matchesForApp:App(name, descriptionText)];
  if ([matches count] != 1)
    return nil;
  return [[matches objectAtIndex:0] keywords];
}

/* The identifiers of every category that matched, in order. */
static NSArray<NSString *> *CategoriesMatchedBy(NSString *name, NSString *descriptionText)
{
  NSArray<AGRiskMatch *> *matches = [LoadedAdviser() matchesForApp:App(name, descriptionText)];
  NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
  AGRiskMatch *match;
  for (match in matches)
    [identifiers addObject:[match.category identifier]];
  return identifiers;
}

/* Every keyword that fired, across every category that did. */
static NSArray<NSString *> *AllKeywordsMatchedBy(NSString *name, NSString *descriptionText)
{
  NSArray<AGRiskMatch *> *matches = [LoadedAdviser() matchesForApp:App(name, descriptionText)];
  NSMutableArray<NSString *> *keywords = [NSMutableArray array];
  AGRiskMatch *match;
  for (match in matches)
    [keywords addObjectsFromArray:[match keywords]];
  return keywords;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* --- the shipped file: every category can say something --- */
  {
    AGRiskAdviser *adviser = LoadedAdviser();
    NSArray<AGRiskCategory *> *categories = [adviser categories];
    PASS([categories count] >= 5, "the risk file carries several categories");

    NSMutableSet *identifiers = [NSMutableSet set];
    AGRiskCategory *category;
    for (category in categories)
      {
        PASS([[category identifier] length] > 0, "a category has an identifier");
        PASS([[category title] length] > 0, "a category has a title");
        PASS([[category shortRisk] length] > 0, "a category has a short sentence");
        PASS([[category shortRisk] hasSuffix:@"."], "the short sentence is a sentence");
        PASS([[category keywords] count] > 0, "a category has keywords");
        PASS(![identifiers containsObject:[category identifier]],
             "no two categories share an identifier");
        [identifiers addObject:[category identifier]];

        /* The panel lists what fired, so a keyword has to survive as written. */
        NSString *keyword;
        for (keyword in [category keywords])
          {
            PASS([keyword isEqualToString:
                       [keyword stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]],
                 "a keyword has no surrounding whitespace");
            PASS([keyword length] > 1, "no keyword is a single character");
          }
      }

    PASS([[adviser disclaimerShort] length] > 0, "the short disclaimer is there");
    PASS([[[adviser disclaimerShort] lowercaseString] rangeOfString:@"not checked"].location
           != NSNotFound,
         "the disclaimer says the app has not been checked");
    PASS([[adviser disclaimerShort] length] < 50, "the short disclaimer stays one short line");
  }

  /* --- the two categories the catalog is full of --- */
  {
    PASS_EQUAL(OnlyCategoryMatchedBy(@"AnchorWallet", @"A desktop wallet for holding coins."),
               @"wallets-crypto",
               "a wallet in the title matches the wallet category");
    PASS_EQUAL(KeywordsMatchedBy(@"AnchorWallet", @"A desktop wallet for holding coins."),
               (@[ @"wallet" ]), "the keyword that fired is reported");

    PASS_EQUAL(OnlyCategoryMatchedBy(@"ClawControl", @"Desktop client for an AI agent with mcp."),
               @"ai-agents",
               "an AI agent in the description matches the AI category");
    PASS_EQUAL(KeywordsMatchedBy(@"ClawControl", @"Desktop client for an AI agent with mcp."),
               (@[ @"ai", @"agent", @"mcp" ]), "every keyword that fired is reported");

    PASS_EQUAL(MatchesOf(@"QuietNotes", @"A plain text editor for your notes."), 0,
               "an ordinary item matches no category");
    PASS_EQUAL(MatchesOf(@"Nothing", nil), 0,
               "an item with no description matches no category");
  }

  /* --- whole-word matching is what keeps the short keywords usable --- */
  {
    PASS_EQUAL(MatchesOf(@"Mailer", @"Send e-mail from your inbox."), 0,
               "email is not the keyword ai");
    PASS_EQUAL(MatchesOf(@"Chair", @"A chair for the garden."), 0,
               "chair is not the keyword ai");
    PASS_EQUAL(MatchesOf(@"Available", @"Available now, everywhere."), 0,
               "available is not the keyword ai");
    PASS_EQUAL(MatchesOf(@"Guide", @"A wastewater treatment chart."), 0,
               "wastewater is not the keyword wallet");

    PASS_EQUAL(OnlyCategoryMatchedBy(@"Sparkle", @"An AI workspace with a local model."),
               @"ai-agents", "AI in capitals is found");
    PASS_EQUAL(OnlyCategoryMatchedBy(@"Sparkle", @"SparkleDesk ships an openai client."),
               @"ai-agents", "a keyword is found in a lower-case compound name");
    PASS_EQUAL(OnlyCategoryMatchedBy(@"GPTDesk", @"A desk for GPT4All models."),
               @"ai-agents", "a digit boundary splits a compound name into findable words");
    PASS_EQUAL(OnlyCategoryMatchedBy(@"Guide", @"Writes wallet recovery phrases for you."),
               @"wallets-crypto", "wallet is found where it is a word of its own");
  }

  /* --- the metadata that is searched --- */
  {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    [item setObject:@"Cate" forKey:@"name"];
    [item setObject:@"An infinite zoomable canvas IDE." forKey:@"description"];
    [item setObject:[NSArray arrayWithObject:@"WalletCategory"] forKey:@"categories"];
    AGApp *app = [[[AGApp alloc] initWithFeedItem:item] retain];
    AGRiskAdviser *adviser = LoadedAdviser();
    NSArray<AGRiskMatch *> *matches = [adviser matchesForApp:app];
    PASS([matches count] == 1, "a category name is metadata and is searched");
    PASS([[adviser searchTextsForApp:app] count] >= 4,
         "the name, the summary, the description and the categories are searched");

    [item setObject:@"Plain" forKey:@"name"];
    [item removeObjectForKey:@"categories"];
    [item removeObjectForKey:@"description"];
    [item setObject:[NSArray arrayWithObject:
                          [NSDictionary dictionaryWithObjectsAndKeys:
                             @"GitHub", @"type",
                             @"https://github.com/someone/bitcoin-wallet", @"url", nil]]
              forKey:@"links"];
    app = [[[AGApp alloc] initWithFeedItem:item] retain];
    PASS([[adviser matchesForApp:app] count] == 1,
         "a linked URL is metadata and is searched");

    PASS([[adviser searchTextsForApp:nil] count] == 0,
         "a nil item searches nothing");
    PASS([[adviser matchesForApp:nil] count] == 0,
         "a nil item matches no category");
  }

  /* --- more than one category, in the order the file lists them --- */
  {
    PASS_EQUAL(CategoriesMatchedBy(@"CoinWallet", @"An AI assistant with a password manager."),
               (@[ @"ai-agents", @"wallets-crypto", @"credential-access" ]),
               "every matching category is reported, in the order the file lists them");
  }

  /* --- a broken file warns about nothing rather than about everything --- */
  {
    AGRiskAdviser *adviser = [AGRiskAdviser adviserWithPropertyList:nil];
    PASS(adviser != nil, "a nil property list still gives an adviser");
    PASS_EQUAL([[adviser categories] count], 0, "no categories survive a nil file");
    PASS_EQUAL([[adviser matchesForApp:App(@"AnchorWallet", @"A wallet.")] count], 0,
               "a missing file matches nothing");

    NSMutableArray *entries = [NSMutableArray array];
    [entries addObject:[NSMutableDictionary dictionary]];   /* no keys at all */
    [entries addObject:@{ @"Identifier" : @"x", @"Title" : @"X", @"ShortRisk" : @"Short." }];
    [entries addObject:@{ @"Identifier" : @"y", @"Title" : @"Y",
                          @"ShortRisk" : @"Short." }];
    [entries addObject:@"not a dictionary"];
    [entries addObject:@{ @"Identifier" : @"z", @"Title" : @"Z",
                          @"ShortRisk" : @"Short.",
                          @"Keywords" : @[ @"  ", @"" ] }];
    [entries addObject:@{ @"Identifier" : @"good", @"Title" : @"Good",
                          @"ShortRisk" : @"Short.",
                          @"Keywords" : @[ @"wallet", @"Wallet", @"AI" ] }];
    adviser = [AGRiskAdviser adviserWithPropertyList:@{ @"Categories" : entries }];
    PASS_EQUAL([[adviser categories] count], 1,
               "only the entry that has everything is kept");
    AGRiskCategory *kept = [[adviser categories] objectAtIndex:0];
    PASS_EQUAL([[kept keywords] count], 2,
               "a keyword repeated in another case is one keyword");
    PASS_EQUAL([kept keywords], (@[ @"wallet", @"AI" ]),
               "the keywords keep the spelling the file wrote");

    adviser = [AGRiskAdviser adviserWithPropertyList:@{ @"Categories" : @"not a list" }];
    PASS_EQUAL([[adviser categories] count], 0,
               "a Categories key of the wrong type is empty");
  }

  /* --- the category the panel shows, read on its own --- */
  {
    NSDictionary *entry = @{ @"Identifier" : @"ai-agents",
                             @"Title" : @"AI",
                             @"ShortRisk" : @"Short.",
                                                          @"Keywords" : @[ @"ai", @"mcp", @"gpt" ] };
    AGRiskCategory *category = [[AGRiskCategory alloc] initWithPropertyListEntry:entry];
    PASS(category != nil, "a complete entry is kept");

    NSArray *one = [NSArray arrayWithObject:@"An AI workspace"];
    NSArray *two = [NSArray arrayWithObjects:@"An AI workspace", @"and MCP", nil];
    NSArray *none = [NSArray array];
    NSArray *embedded = [NSArray arrayWithObject:@"mail availability"];

    PASS_EQUAL([[category keywordsMatchedInTexts:one] count], 1,
               "one keyword of three matched");
    PASS_EQUAL([category keywordsMatchedInTexts:two], (@[ @"ai", @"mcp" ]),
               "keywords are reported in the order the file lists them");
    PASS_EQUAL([[category keywordsMatchedInTexts:none] count], 0,
               "no texts match nothing");
    PASS_EQUAL([[category keywordsMatchedInTexts:embedded] count], 0,
               "words that merely contain a keyword do not match");
    PASS([[AGRiskCategory alloc] initWithPropertyListEntry:nil] == nil,
         "a nil entry is no category");
    PASS_EQUAL([[[[AGRiskCategory alloc] initWithPropertyListEntry:entry] keywords] count], 3,
               "every read of the same entry agrees on its keywords");
    PASS_EQUAL(CategoriesMatchedBy(@"CoinWallet", @"An AI assistant with a wallet."),
               (@[ @"ai-agents", @"wallets-crypto" ]),
               "matchesForApp works through the shipped file");
  }

  /* --- the match value object --- */
  {
    AGRiskCategory *category = [[AGRiskCategory alloc] initWithPropertyListEntry:
                                  @{ @"Identifier" : @"a", @"Title" : @"A",
                                     @"ShortRisk" : @"S.",
                                     @"Keywords" : @[ @"x" ] }];
    AGRiskMatch *match = [[[AGRiskMatch alloc] initWithCategory:category
                                                        keywords:@[ @"x" ]] retain];
    PASS_EQUAL([[match category] identifier], @"a", "the match keeps its category");
    PASS_EQUAL([[match keywords] count], 1, "the match keeps its keywords");
    PASS([[AGRiskMatch alloc] initWithCategory:nil keywords:nil] == nil,
         "a match without a category is no match");
  }

  /* --- a whole catalog file, parsed by the parser and then matched --- */
  {
    /* The fixture a manual test points AGFeedURL at: one item in a category,
     * one that matches nothing and one that matches several. Reading it here
     * keeps the panel's inputs (the parser's output) honest. */
    NSData *data = [NSData dataWithContentsOfFile:@"../../Fixtures/feed-risk.json"];
    AGCatalog *catalog = [AGFeedParser catalogFromData:data
                                             fetchDate:nil
                                                 error:NULL];
    AGRiskAdviser *adviser = LoadedAdviser();

    PASS([[catalog apps] count] == 3, "the fixture holds three items");
    PASS([[catalog appNamed:@"AiyoPerps"] name] != nil, "the fixture parsed");

    AGApp *agent = [catalog appNamed:@"AiyoPerps"];
    NSArray<AGRiskMatch *> *matches = [adviser matchesForApp:agent];
    PASS([matches count] == 1, "one category matches the AI fixture item");
    PASS_EQUAL([[[matches objectAtIndex:0] category] identifier], @"ai-agents",
               "the AI fixture item is in the AI category");
    PASS_EQUAL([[[matches objectAtIndex:0] keywords] count], 3,
               "the AI fixture item reports three keywords");

    AGApp *wallet = [catalog appNamed:@"AnchorWallet"];
    matches = [adviser matchesForApp:wallet];
    PASS([matches count] == 1, "one category matches the wallet fixture item");
    PASS_EQUAL([[[matches objectAtIndex:0] category] identifier], @"wallets-crypto",
               "the wallet fixture item is in the wallet category");

    PASS([[adviser matchesForApp:[catalog appNamed:@"QuietNotes"]] count] == 0,
         "the plain fixture item matches nothing");

    PASS_EQUAL(AllKeywordsMatchedBy(@"CryptoAgentVault",
                                    @"An AI agent with a wallet, a password manager and a VPN."),
               (@[ @"ai", @"agent", @"wallet", @"crypto", @"password manager", @"vpn" ]),
               "every keyword of every matching category is reported");
    PASS_EQUAL(CategoriesMatchedBy(@"CryptoAgentVault",
                                    @"An AI agent with a wallet, a password manager and a VPN."),
               (@[ @"ai-agents", @"wallets-crypto", @"credential-access", @"vpn-proxy" ]),
               "four categories match an item that belongs to four");

    [agent release];
    [wallet release];
  }

  [arp release];
  return 0;
}