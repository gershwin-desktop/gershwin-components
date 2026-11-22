/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCImage;

/* One recognized word: its text and its box in image pixels, origin top left */
@interface SCRecognizedWord : NSObject
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSRect box;
/* Words of one line share a line number, counted through the page */
@property (nonatomic, readonly) NSUInteger line;
- (instancetype) initWithText: (NSString *)text box: (NSRect)box line: (NSUInteger)line;
@end

/*
 * Writes scans as PDF: one page per image, sized by the scan resolution;
 * black and white pages fax-compressed (CCITT G4), others lossless. Pages
 * with recognized words get them as invisible text over the image, so the
 * PDF can be searched and its text selected and copied. The text is set in
 * a font without visible glyphs (tesseract's pdf.ttf), which is the font
 * file `textFont` must name when any page has words.
 */
@interface SCPDFWriter : NSObject

/* words: one array of SCRecognizedWord per image, or NSNull for no text */
+ (BOOL) writePDFWithImages: (NSArray *)images
                      words: (NSArray *)words
                   textFont: (NSString *)textFont
                     toFile: (NSString *)path
                      error: (NSError **)error;

@end
