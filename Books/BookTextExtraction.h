/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Turns a range of the book's reading text into what the user expects on the
// pasteboard: the words as read, with paragraph breaks, and without the
// invisible characters (soft hyphens, attachment placeholders) or the reader's
// theme colours that only make sense on the page. Page furniture such as folios
// is painted by the page view and never part of the reading text, so it cannot
// leak into a copy.
@interface BookTextExtraction : NSObject

+ (NSString *)plainTextInRange:(NSRange)range ofString:(NSString *)string;
+ (NSAttributedString *)richTextInRange:(NSRange)range ofText:(NSAttributedString *)text;

// Declares plain text and RTF; the pasteboard is a parameter so tests can use
// a private named one instead of the user's clipboard.
+ (BOOL)writeRange:(NSRange)range
            ofText:(NSAttributedString *)text
      toPasteboard:(NSPasteboard *)pasteboard;

@end
