/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class SCImage;

typedef NS_ENUM(NSInteger, SCRecognitionState)
{
  SCRecognitionNone,       /* never given to the background worker */
  SCRecognitionPending,
  SCRecognitionDone,
  SCRecognitionFailed
};

/* Posted on the main thread when the worker finished a page (object: the page) */
extern NSString * const SCTextRecognizerDidFinishPageNotification;

/*
 * Recognizes the text on scanned pages with tesseract, which is run as a
 * program, so PDFs get the text as an invisible layer over each page: the
 * pages look exactly as scanned, but text can be found, selected and
 * copied. Optional; nothing else needs tesseract.
 */
@interface SCTextRecognizer : NSObject

/* nil when tesseract is not installed */
+ (NSString *) tesseractPath;

/* Installed recognition languages ("eng", "deu", ...), without helper data */
+ (NSArray *) installedLanguages;

/*
 * Looks again at what is installed; when the languages changed, pages still
 * known are recognized again with them. YES when something changed.
 */
+ (BOOL) reloadInstallation;

/* Drops what is known about pages that were saved or thrown away */
+ (void) forgetImages: (NSArray *)images;

/* Queues every page still known for recognition again */
+ (void) recognizeAgain;

/* YES when OCR can be offered: tesseract and at least one language */
+ (BOOL) isAvailable;

/*
 * tesseract's language argument ("deu+eng") for languages or locales
 * ("de", "en") in the order the user prefers them, limited to what is installed; English when
 * nothing matches and it is installed, else the first installed language
 */
+ (NSString *) languagesForUserLanguages: (NSArray *)userLanguages
                               installed: (NSArray *)installed;

/* tesseract's languages ("deu+eng") for the user's preferred languages */
+ (NSString *) userLanguages;

/* The invisible font tesseract ships for text layers (pdf.ttf) */
+ (NSString *) textFontPath;

/*
 * Starts recognizing a page in the background right away, one page at a
 * time, so that by the time it is saved its text is usually known
 */
+ (void) startRecognizingImage: (SCImage *)image;

/*
 * Same, but reads the text from `source`, a version of the page with the
 * same pixel size: tesseract does better on the gray original than on the
 * black and white page that gets saved
 */
+ (void) startRecognizingImage: (SCImage *)image fromImage: (SCImage *)source;

/* tesseract code ("deu", "chi_tra") for a language or locale ("de", "zh-Hant") */
+ (NSString *) codeForLanguage: (NSString *)identifier;

/* English name of a language, for messages ("German" for "de") */
+ (NSString *) displayNameForLanguage: (NSString *)identifier;

/* The same for a tesseract code ("French" for "fra") */
+ (NSString *) displayNameForCode: (NSString *)code;

/* The user's preferred languages that are not installed for tesseract */
+ (NSArray *) missingUserLanguages;

+ (SCRecognitionState) stateForImage: (SCImage *)image;

/* The script tesseract saw on a page read in the background ("Latin"), or nil */
+ (NSString *) scriptForImage: (SCImage *)image;

/* The page's words; waits for a started recognition, or runs one now */
+ (NSArray *) wordsForImage: (SCImage *)image error: (NSError **)error;

/* Blocking (see above): call off the main thread */
+ (NSArray *) recognizeWordsInImage: (SCImage *)image
                          languages: (NSString *)languages
                              error: (NSError **)error;

/* PDF with the pages' recognized text as an invisible layer; blocking */
+ (BOOL) writeSearchablePDFWithImages: (NSArray *)images
                               toFile: (NSString *)path
                                error: (NSError **)error;

@end
