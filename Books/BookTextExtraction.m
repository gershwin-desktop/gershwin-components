/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BookTextExtraction.h"

// Attributes worth carrying to another application: they describe how the
// author styled the text. Everything else on the reading text is the reader's
// own (theme colours, highlight backgrounds, page-break markers, attachments).
static NSArray *ExportedAttributes(void)
{
  // alloc/init rather than a literal: the tests compile this file without ARC,
  // where an autoreleased literal would leave the static dangling.
  static NSArray *names = nil;
  if (names == nil)
    names = [[NSArray alloc] initWithObjects:
               NSFontAttributeName, NSParagraphStyleAttributeName,
               NSUnderlineStyleAttributeName, NSStrikethroughStyleAttributeName,
               NSSuperscriptAttributeName, NSBaselineOffsetAttributeName,
               NSObliquenessAttributeName, NSExpansionAttributeName,
               NSKernAttributeName, NSLigatureAttributeName, NSLinkAttributeName, nil];
  return names;
}

static NSRange ClampedRange(NSRange range, NSUInteger length)
{
  if (range.location == NSNotFound || range.location >= length)
    return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(range.location, MIN(range.length, length - range.location));
}

// Characters that only matter for layout on the page: a soft hyphen is a
// possible break point, U+FFFC stands in for an inline image, zero-width
// spaces and BOMs are invisible. A copy must read as the words do.
static BOOL IsDroppedCharacter(unichar c)
{
  return c == 0x00AD || c == 0xFFFC || c == 0x200B || c == 0xFEFF;
}

static BOOL IsLineBreak(unichar c)
{
  return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029;
}

static BOOL IsHorizontalSpace(unichar c)
{
  return c == ' ' || c == '\t';
}

// Apply the plain-text rules to `text` in place, from the end so that deletions
// do not shift indexes still to be visited: drop layout characters, turn every
// kind of line or paragraph separator into one "\n", and drop the spaces the
// markup leaves before a line break, which the page never shows.
static void NormalizeInPlace(NSMutableAttributedString *text)
{
  NSString *s = [text string];
  NSUInteger i = [s length];
  BOOL beforeBreak = NO;
  while (i > 0)
    {
      i--;
      unichar c = [s characterAtIndex:i];
      if (IsDroppedCharacter(c))
        {
          [text deleteCharactersInRange:NSMakeRange(i, 1)];
          continue;
        }
      if (IsLineBreak(c))
        {
          // "\r\n" is one break: drop the "\r" in front of a "\n" already kept.
          if (c == '\r' && i + 1 < [s length] && [s characterAtIndex:i + 1] == '\n')
            {
              [text deleteCharactersInRange:NSMakeRange(i, 1)];
              continue;
            }
          if (c != '\n')
            [text replaceCharactersInRange:NSMakeRange(i, 1) withString:@"\n"];
          beforeBreak = YES;
          continue;
        }
      if (beforeBreak && IsHorizontalSpace(c))
        {
          [text deleteCharactersInRange:NSMakeRange(i, 1)];
          continue;
        }
      beforeBreak = NO;
    }
}

@implementation BookTextExtraction

+ (NSString *)plainTextInRange:(NSRange)range ofString:(NSString *)string
{
  NSRange r = ClampedRange(range, [string length]);
  if (r.location == NSNotFound || r.length == 0)
    return @"";
  NSMutableAttributedString *m = [[NSMutableAttributedString alloc]
    initWithString:[string substringWithRange:r]];
  NormalizeInPlace(m);
  return [[m string] copy];
}

+ (NSAttributedString *)richTextInRange:(NSRange)range ofText:(NSAttributedString *)text
{
  NSRange r = ClampedRange(range, [text length]);
  if (r.location == NSNotFound || r.length == 0)
    return [[NSAttributedString alloc] initWithString:@""];
  NSAttributedString *sub = [text attributedSubstringFromRange:r];
  NSMutableAttributedString *m = [[NSMutableAttributedString alloc]
    initWithString:[sub string]];
  NSArray *keep = ExportedAttributes();
  NSUInteger loc = 0;
  NSUInteger len = [sub length];
  while (loc < len)
    {
      NSRange eff;
      NSDictionary *attrs = [sub attributesAtIndex:loc effectiveRange:&eff];
      NSMutableDictionary *out = [NSMutableDictionary dictionary];
      for (NSString *k in keep)
        {
          id v = [attrs objectForKey:k];
          if (v != nil)
            [out setObject:v forKey:k];
        }
      if ([out count] > 0)
        [m setAttributes:out range:eff];
      loc = NSMaxRange(eff);
    }
  NormalizeInPlace(m);
  return m;
}

+ (BOOL)writeRange:(NSRange)range
            ofText:(NSAttributedString *)text
      toPasteboard:(NSPasteboard *)pasteboard
{
  NSAttributedString *rich = [self richTextInRange:range ofText:text];
  if ([rich length] == 0)
    return NO;
  [pasteboard declareTypes:@[ NSStringPboardType, NSRTFPboardType ] owner:nil];
  BOOL ok = [pasteboard setString:[rich string] forType:NSStringPboardType];
  NSData *rtf = [rich RTFFromRange:NSMakeRange(0, [rich length])
                documentAttributes:@{}];
  if (rtf == nil)
    return NO;
  return ok && [pasteboard setData:rtf forType:NSRTFPboardType];
}

@end
