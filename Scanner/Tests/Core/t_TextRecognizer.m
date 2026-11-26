/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * t_TextRecognizer - searchable PDFs through tesseract. Needs tesseract with
 * English data and poppler-utils; renders its own text page with cairo, so
 * it stays headless.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCImage.h"
#import "SCTextRecognizer.h"
#import "SCLanguageGuess.h"
#include <cairo.h>
#include <string.h>

/* 4 x 2 inches at 300 dpi with two lines of large, plain text */
static SCImage *
TextPageWithLines(const char *first, const char *second)
{
  int w = 1200, h = 600, x, y, stride;
  cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
  cairo_t *cr = cairo_create(s);
  NSMutableData *gray = [NSMutableData dataWithLength: w * h];
  uint8_t *g = [gray mutableBytes];
  const uint8_t *src;

  cairo_set_source_rgb(cr, 1, 1, 1);
  cairo_paint(cr);
  cairo_set_source_rgb(cr, 0, 0, 0);
  cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL,
                         CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size(cr, 90);
  cairo_move_to(cr, 60, 220);
  cairo_show_text(cr, first);
  cairo_move_to(cr, 60, 420);
  cairo_show_text(cr, second);
  cairo_destroy(cr);
  cairo_surface_flush(s);
  src = cairo_image_surface_get_data(s);
  stride = cairo_image_surface_get_stride(s);
  for (y = 0; y < h; y++)
    {
      for (x = 0; x < w; x++)
        {
          g[y * w + x] = src[y * stride + x * 4];
        }
    }
  cairo_surface_destroy(s);
  return [[[SCImage alloc] initWithWidth: w height: h samplesPerPixel: 1
                           bitsPerSample: 8 pixels: gray resolution: 300]
           autorelease];
}

static NSString *
Run(NSArray *arguments)
{
  NSTask *task = [[NSTask new] autorelease];
  NSPipe *pipe = [NSPipe pipe];
  NSData *out;

  [task setLaunchPath: @"/usr/bin/env"];
  [task setArguments: arguments];
  [task setStandardOutput: pipe];
  [task launch];
  out = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  return [[[NSString alloc] initWithData: out encoding: NSUTF8StringEncoding]
           autorelease];
}

static SCImage *
TextPage(void)
{
  return TextPageWithLines("SCANNER TEST", "Searchable page");
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_TextRecognizer-%d", getpid()]];
  NSString *path = [dir stringByAppendingPathComponent: @"ocr.pdf"];
  NSArray *installed = [NSArray arrayWithObjects: @"eng", @"deu", @"fra", nil];
  NSArray *user;
  NSArray *pages;
  NSString *text, *info, *images, *boxes;
  SCImage *bw;
  NSError *error = nil;
  SCImage *page;

  START_SET("languages")
    {
      user = [NSArray arrayWithObjects: @"de", @"en", nil];
      PASS_EQUAL([SCTextRecognizer languagesForUserLanguages: user installed: installed],
                 @"deu+eng", "preferred languages in their order, as tesseract codes");
      user = [NSArray arrayWithObjects: @"tlh", nil];
      PASS_EQUAL([SCTextRecognizer languagesForUserLanguages: user installed: installed],
                 @"eng", "English when no preferred language is installed");
      user = [NSArray arrayWithObjects: @"es", nil];
      installed = [NSArray arrayWithObjects: @"fra", nil];
      PASS_EQUAL([SCTextRecognizer languagesForUserLanguages: user installed: installed],
                 @"fra", "first installed language when there is no English");
      PASS_EQUAL([SCTextRecognizer codeForLanguage: @"pt_BR"], @"por",
                 "any locale maps to its language's code, not only listed ones");
      PASS_EQUAL([SCTextRecognizer codeForLanguage: @"cs"], @"ces",
                 "ISO 639-2/T codes as tesseract names its data");
      PASS_EQUAL([SCTextRecognizer codeForLanguage: @"zh-Hant"], @"chi_tra",
                 "traditional Chinese has its own data");
      PASS_EQUAL([SCTextRecognizer codeForLanguage: @"zh"], @"chi_sim",
                 "Chinese is simplified by default");
      PASS_EQUAL([SCTextRecognizer displayNameForCode: @"fra"], @"French",
                 "tesseract codes get English names for messages");
      PASS_EQUAL([SCTextRecognizer displayNameForCode: @"chi_tra"],
                 @"Traditional Chinese", "Chinese names its script");
    }
  END_SET("languages")

  NEED(PASS([SCTextRecognizer tesseractPath] != nil
            && [[SCTextRecognizer installedLanguages] containsObject: @"eng"],
            "tesseract with English is installed (needed by the tests below)"));
  PASS(![[SCTextRecognizer installedLanguages] containsObject: @"osd"],
       "orientation data is not offered as a language");
  PASS([fm fileExistsAtPath: [SCTextRecognizer textFontPath]],
       "tesseract's invisible font is found in its data directory");

  [fm removeItemAtPath: dir error: NULL];
  [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                 attributes: nil error: NULL];

  page = TextPage();
  bw = [page blackAndWhiteImageWithThreshold: 128];
  /* As the app does: the saved page is black and white, the text is read from gray */
  [SCTextRecognizer startRecognizingImage: bw fromImage: page];
  pages = [NSArray arrayWithObjects: page, bw, nil];
  PASS([SCTextRecognizer writeSearchablePDFWithImages: pages toFile: path
                                                error: &error],
       "searchable PDF is written");
  text = Run([NSArray arrayWithObjects: @"pdftotext", path, @"-", nil]);
  PASS([[text componentsSeparatedByString: @"SCANNER TEST"] count] == 3,
       "both pages carry the recognized text, with the space between words");
  PASS([text rangeOfString: @"Searchable page"].location != NSNotFound,
       "the second line is there too");
  info = Run([NSArray arrayWithObjects: @"pdfinfo", path, nil]);
  PASS([info rangeOfString: @"Pages:           2"].location != NSNotFound,
       "one PDF page per image");
  PASS([info rangeOfString: @"Page size:       288 x 144 pts"].location != NSNotFound,
       "page size follows the scan resolution");
  images = Run([NSArray arrayWithObjects: @"pdfimages", @"-list", path, nil]);
  PASS([images rangeOfString: @"ccitt"].location != NSNotFound,
       "the black and white page stays fax-compressed");
  boxes = Run([NSArray arrayWithObjects: @"pdftotext", @"-bbox", @"-f", @"1",
                       @"-l", @"1", path, @"-", nil]);
  {
    /* "SCANNER" starts 60 px from the left at 300 dpi, i.e. at 14.4 pt */
    NSRange r = [boxes rangeOfString: @"\">SCANNER<"];
    NSString *before = r.location != NSNotFound
      ? [boxes substringToIndex: r.location] : @"";
    NSRange x = [before rangeOfString: @"xMin=\"" options: NSBackwardsSearch];
    double xMin = x.location != NSNotFound
      ? [[before substringFromIndex: NSMaxRange(x)] doubleValue] : -1;

    PASS(xMin > 12 && xMin < 18, "words sit where they are on the scan");
  }
  PASS([[fm contentsOfDirectoryAtPath: dir error: NULL] count] == 1,
       "nothing but the PDF is left behind");

  /* As after installing a language: pages already read are read again */
  PASS([SCTextRecognizer stateForImage: bw] == SCRecognitionDone,
       "the page was recognized in the background");
  [SCTextRecognizer recognizeAgain];
  PASS([SCTextRecognizer stateForImage: bw] == SCRecognitionPending,
       "a language change queues known pages again");
  {
    NSArray *again = [SCTextRecognizer wordsForImage: bw error: &error];
    NSString *joined = [[again valueForKey: @"text"] componentsJoinedByString: @" "];

    PASS([joined rangeOfString: @"SCANNER TEST"].location != NSNotFound
         && [SCTextRecognizer stateForImage: bw] == SCRecognitionDone,
         "saving meanwhile waits for the new result, from the gray original");
  }

  /* A page in an alphabet no installed language covers */
  {
    SCImage *cyrillic = TextPageWithLines("Привет, это проверка",
                                          "распознавания текста");
    NSString *script;

    [SCTextRecognizer startRecognizingImage: cyrillic];
    [SCTextRecognizer wordsForImage: cyrillic error: NULL];
    script = [SCTextRecognizer scriptForImage: cyrillic];
    PASS_EQUAL(script, @"Cyrillic", "the worker reports the page's script");
    PASS_EQUAL(SCLanguageForScript(script), @"rus",
               "which leads to suggesting Russian");
    PASS_EQUAL([SCTextRecognizer scriptForImage: page], nil,
               "pages never given to the worker have no script");
    [SCTextRecognizer forgetImages: [NSArray arrayWithObject: cyrillic]];
  }

  PASS([SCTextRecognizer recognizeWordsInImage: page languages: @"xx_nonexistent"
                                         error: &error] == nil
       && [[error localizedDescription] length] > 0,
       "a missing language fails with a message instead of no text");

  [fm removeItemAtPath: dir error: NULL];
  [arp release];
  return 0;
}
