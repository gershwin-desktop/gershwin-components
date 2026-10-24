/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AGApp.h"
#import "AGAuthor.h"
#import "AGLink.h"

// Both feed hosts live in one place: assets on the pages host, the per-app
// page on the site host, so a host change is a single edit.
static NSString * const AGDatabaseBaseString = @"https://appimage.github.io/database/";
static NSString * const AGSiteBaseString = @"https://appimage.github.io/";

static NSString *AGStringValue(id value)
{
  if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
    return value;
  return nil;
}

static NSString *AGFirstStringInArray(id value)
{
  if (![value isKindOfClass:[NSArray class]] || [(NSArray *)value count] == 0)
    return nil;
  id first = [(NSArray *)value objectAtIndex:0];
  return [first isKindOfClass:[NSString class]] ? first : nil;
}

// Asset paths are relative to the database directory, but a few items ship an
// absolute address; only those are taken as they are, never rewritten.
static NSURL *AGAssetURL(NSString *path)
{
  if ([path length] == 0)
    return nil;

  NSString *loweredPath = [path lowercaseString];
  if ([loweredPath hasPrefix:@"http://"] || [loweredPath hasPrefix:@"https://"])
    return [NSURL URLWithString:path];

  return [NSURL URLWithString:[AGDatabaseBaseString stringByAppendingString:path]];
}

// SVG artwork cannot be decoded here, so a card asks for the placeholder
// instead of an icon that would never appear (see FEED.md, "Assets").
static BOOL AGIsBitmapPath(NSString *path)
{
  NSString *extension = [[path pathExtension] lowercaseString];
  return [extension isEqualToString:@"png"]
    || [extension isEqualToString:@"jpg"]
    || [extension isEqualToString:@"jpeg"];
}

static NSURL *AGLinkURL(NSArray *links, NSString *wantedType)
{
  AGLink *link;
  for (link in links)
    {
      if ([[link type] isEqualToString:wantedType])
        return [link url];
    }
  return nil;
}

// The card shows one line: the first line, else the first sentence, and only
// then a hard cut, so ordinary descriptions stay readable instead of being
// truncated mid-clause at a fixed count.
/* Some publishers paste HTML into the feed's description ("<p>Client for
 * ChartCaddy online..."), which a card must not show verbatim. Paragraph
 * and line-break tags become newlines, every other tag disappears and the
 * common entities are decoded; the text is never parsed further than that.
 * Nil stays nil, so an item without a description keeps meaning that. */
static NSString *AGPlainText(NSString *text)
{
  if (text == nil || [text rangeOfString:@"<"].location == NSNotFound)
    return text;

  NSMutableString *plain = [NSMutableString stringWithCapacity:[text length]];
  NSScanner *scanner = [NSScanner scannerWithString:text];
  [scanner setCharactersToBeSkipped:nil];
  while (![scanner isAtEnd])
    {
      NSString *chunk = nil;
      if ([scanner scanUpToString:@"<" intoString:&chunk])
        [plain appendString:chunk];
      if ([scanner isAtEnd])
        break;
      NSString *tag = nil;
      [scanner scanString:@"<" intoString:NULL];
      [scanner scanUpToString:@">" intoString:&tag];
      [scanner scanString:@">" intoString:NULL];
      NSString *name = [[[tag componentsSeparatedByCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]] firstObject] lowercaseString];
      if ([name isEqualToString:@"/p"] || [name isEqualToString:@"br"]
          || [name isEqualToString:@"br/"] || [name isEqualToString:@"/li"])
        [plain appendString:@"\n"];
    }

  NSDictionary *entities = @{ @"&amp;" : @"&", @"&lt;" : @"<", @"&gt;" : @">",
                              @"&quot;" : @"\"", @"&#39;" : @"'", @"&nbsp;" : @" " };
  for (NSString *entity in entities)
    [plain replaceOccurrencesOfString:entity withString:[entities objectForKey:entity]
                              options:0 range:NSMakeRange(0, [plain length])];
  return [plain stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *AGSummaryFromDescription(NSString *descriptionText)
{
  if (descriptionText == nil)
    return nil;

  NSString *summary = descriptionText;
  NSRange newline = [summary rangeOfString:@"\n"];
  if (newline.location != NSNotFound)
    summary = [summary substringToIndex:newline.location];

  if ([summary length] > 90)
    {
      NSRange sentenceEnd = [summary rangeOfString:@". "];
      if (sentenceEnd.location != NSNotFound)
        summary = [summary substringToIndex:sentenceEnd.location + 1];
    }

  summary = [summary stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];

  if ([summary length] > 90)
    summary = [[summary substringToIndex:89] stringByAppendingString:@"\u2026"];

  return summary;
}

@implementation AGApp

- (instancetype)initWithFeedItem:(NSDictionary *)item
{
  if (![item isKindOfClass:[NSDictionary class]])
    return nil;

  NSString *name = AGStringValue([item objectForKey:@"name"]);
  if (name == nil)
    return nil;

  self = [super init];
  if (self == nil)
    return nil;

  _name = [name copy];
  _displayName = [[name stringByReplacingOccurrencesOfString:@"_" withString:@" "] copy];
  _descriptionText = [AGPlainText(AGStringValue([item objectForKey:@"description"])) copy];
  _summary = [AGSummaryFromDescription(_descriptionText) copy];
  _license = [AGStringValue([item objectForKey:@"license"]) copy];
  _glibcRequired = [AGStringValue([item objectForKey:@"glibc_required"]) copy];

  NSMutableArray *categories = [NSMutableArray array];
  id categoryValue = [item objectForKey:@"categories"];
  if ([categoryValue isKindOfClass:[NSArray class]])
    {
      id entry;
      for (entry in categoryValue)
        {
          if ([entry isKindOfClass:[NSString class]] && [(NSString *)entry length] > 0)
            [categories addObject:entry];
        }
    }
  _categories = [categories copy];

  NSMutableArray *authors = [NSMutableArray array];
  id authorValue = [item objectForKey:@"authors"];
  if ([authorValue isKindOfClass:[NSArray class]])
    {
      id entry;
      for (entry in authorValue)
        {
          AGAuthor *author = [[AGAuthor alloc] initWithFeedAuthor:entry];
          if (author != nil)
            [authors addObject:author];
        }
    }
  _authors = [authors copy];

  NSMutableArray *links = [NSMutableArray array];
  id linkValue = [item objectForKey:@"links"];
  if ([linkValue isKindOfClass:[NSArray class]])
    {
      id entry;
      for (entry in linkValue)
        {
          if (![entry isKindOfClass:[NSDictionary class]])
            continue;
          id type = [entry objectForKey:@"type"];
          id URLString = [entry objectForKey:@"url"];
          if (![type isKindOfClass:[NSString class]] || ![URLString isKindOfClass:[NSString class]])
            continue;
          [links addObject:[[AGLink alloc] initWithType:type URLString:URLString]];
        }
    }
  _links = [links copy];

  NSString *iconPath = AGFirstStringInArray([item objectForKey:@"icons"]);
  if (AGIsBitmapPath(iconPath))
    _iconURL = AGAssetURL(iconPath);

  NSString *screenshotPath = AGFirstStringInArray([item objectForKey:@"screenshots"]);
  if (screenshotPath != nil)
    _screenshotURL = AGAssetURL(screenshotPath);

  // The GitHub link wins when it exists; a releases page is only consulted
  // for items that never linked GitHub at all.
  NSString *repo = nil;
  BOOL sawGitHubLink = NO;
  AGLink *link;
  for (link in _links)
    {
      if ([[link type] isEqualToString:@"GitHub"])
        {
          sawGitHubLink = YES;
          repo = [AGLink repoPathInURLString:[link URLString]];
          break;
        }
    }
  if (!sawGitHubLink)
    {
      for (link in _links)
        {
          NSString *type = [link type];
          if ([type isEqualToString:@"Download"] || [type isEqualToString:@"Install"])
            {
              repo = [AGLink releaseRepoPathInURLString:[link URLString]];
              if (repo != nil)
                break;
            }
        }
    }
  _githubRepo = [repo copy];
  if (_githubRepo != nil)
    _githubURL = [NSURL URLWithString:[@"https://github.com/" stringByAppendingString:_githubRepo]];

  _downloadPageURL = AGLinkURL(_links, @"Download");
  if (_downloadPageURL == nil)
    _downloadPageURL = AGLinkURL(_links, @"Install");

  _catalogPageURL = [NSURL URLWithString:[AGSiteBaseString stringByAppendingString:
                                            [_name stringByAppendingString:@"/"]]];

  id selfContainedValue = [item objectForKey:@"self_contained"];
  if ([selfContainedValue isKindOfClass:[NSNumber class]])
    {
      _selfContained = [(NSNumber *)selfContainedValue boolValue];
      _selfContainedPresent = YES;
    }

  return self;
}

@end
