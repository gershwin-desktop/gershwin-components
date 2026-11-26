/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCTextRecognizer.h"
#import "SCImageWriter.h"
#import "SCImageBuilder.h"
#import "SCPDFWriter.h"
#import "SCImage.h"
#include <unicode/uloc.h>
#include <string.h>
#include <unistd.h>

static NSError *
SCOCRError(NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 4
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Could not make the PDF searchable: %@",
                                         reason]}];
}

/*
 * Runs a program to completion; returns its exit status, -1 when it cannot
 * start. Standard error is kept apart, so warnings never mix into output.
 */
static int
SCRun(NSString *path, NSArray *arguments, NSString **output, NSString **errors)
{
  NSTask *task = [NSTask new];
  NSPipe *outPipe = [NSPipe pipe];
  NSPipe *errPipe = [NSPipe pipe];
  NSData *outData, *errData;

  [task setLaunchPath: path];
  [task setArguments: arguments];
  [task setStandardOutput: outPipe];
  [task setStandardError: errPipe];
  [task setStandardInput: [NSFileHandle fileHandleWithNullDevice]];
  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      return -1;
    }
  /* Read before waiting: a full pipe would block tesseract forever */
  outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
  errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];
  if (output)
    {
      *output = [[NSString alloc] initWithData: outData encoding: NSUTF8StringEncoding];
    }
  if (errors)
    {
      *errors = [[NSString alloc] initWithData: errData encoding: NSUTF8StringEncoding];
    }
  return [task terminationStatus];
}

/* What became of one page given to the background worker */
@interface SCRecognition : NSObject
@property (nonatomic, strong) SCImage *source;
@property (nonatomic, strong) NSArray *words;
@property (nonatomic, copy) NSString *script;
@property (nonatomic, strong) NSError *error;
@property (nonatomic) BOOL done;
/* Bumped when the page is queued again; a run of an older one is thrown away */
@property (nonatomic) NSUInteger generation;
@end

@implementation SCRecognition
@end

NSString * const SCTextRecognizerDidFinishPageNotification
  = @"SCTextRecognizerDidFinishPageNotification";

static NSCondition *queueCondition;
static NSMutableArray *queuedImages;
/* Pages stay known until +forgetImages: says they were saved or thrown away */
static NSMapTable *recognitions;

@implementation SCTextRecognizer

+ (NSString *) tesseractPath
{
  NSString *envPath = [[[NSProcessInfo processInfo] environment]
                        objectForKey: @"PATH"];
  NSMutableArray *dirs = [NSMutableArray array];

  if (envPath != nil)
    {
      [dirs addObjectsFromArray: [envPath componentsSeparatedByString: @":"]];
    }
  /*
   * Desktop sessions often start apps with a minimal PATH, while ports and
   * packages put tesseract into /usr/local (FreeBSD, OpenBSD) or /usr/pkg
   * (NetBSD)
   */
  [dirs addObjectsFromArray: @[@"/usr/bin", @"/usr/local/bin", @"/usr/pkg/bin"]];
  for (NSString *dir in dirs)
    {
      NSString *candidate = [dir stringByAppendingPathComponent: @"tesseract"];

      if ([dir length] > 0
          && [[NSFileManager defaultManager] isExecutableFileAtPath: candidate])
        {
          return candidate;
        }
    }
  return nil;
}

static NSArray *cachedLanguages;
static NSString *cachedDataDirectory;

/* Asked on every rebuild of the options; tesseract does not change meanwhile */
+ (void) queryInstallation
{
  NSString *tesseract;
  NSString *output = nil;
  NSMutableArray *languages = [NSMutableArray array];
  NSArray *lines;
  NSRange q1, q2;
  NSUInteger i;

  if (cachedLanguages != nil)
    {
      return;
    }
  cachedLanguages = languages;
  tesseract = [self tesseractPath];
  if (tesseract == nil || SCRun(tesseract, @[@"--list-langs"], &output, NULL) != 0)
    {
      return;
    }
  /* The first line names the data directory in quotes, then one language per line */
  lines = [output componentsSeparatedByString: @"\n"];
  q1 = [[lines objectAtIndex: 0] rangeOfString: @"\""];
  q2 = [[lines objectAtIndex: 0] rangeOfString: @"\"" options: NSBackwardsSearch];
  if (q1.location != NSNotFound && q2.location > q1.location)
    {
      cachedDataDirectory = [[lines objectAtIndex: 0] substringWithRange:
        NSMakeRange(NSMaxRange(q1), q2.location - NSMaxRange(q1))];
    }
  for (i = 1; i < [lines count]; i++)
    {
      NSString *l = [[lines objectAtIndex: i] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];

      /* osd only detects orientation and script; it cannot read text */
      if ([l length] > 0 && ![l isEqualToString: @"osd"]
          && [l rangeOfString: @" "].location == NSNotFound)
        {
          [languages addObject: l];
        }
    }
}

+ (BOOL) reloadInstallation
{
  NSArray *before = cachedLanguages;

  cachedLanguages = nil;
  cachedDataDirectory = nil;
  if (before == nil || [before isEqualToArray: [self installedLanguages]])
    {
      return NO;
    }
  /* Pages read with the old languages are read again, e.g. for their umlauts */
  [self recognizeAgain];
  return YES;
}

+ (void) forgetImages: (NSArray *)images
{
  if (queueCondition == nil)
    {
      return;
    }
  [queueCondition lock];
  for (SCImage *image in images)
    {
      [recognitions removeObjectForKey: image];
      [queuedImages removeObject: image];
    }
  [queueCondition unlock];
}

+ (void) recognizeAgain
{
  if (queueCondition == nil)
    {
      return;
    }
  [queueCondition lock];
  for (SCImage *image in [[recognitions keyEnumerator] allObjects])
    {
      SCRecognition *r = [recognitions objectForKey: image];

      [r setGeneration: [r generation] + 1];
      [r setDone: NO];
      [r setWords: nil];
      [r setError: nil];
      if (![queuedImages containsObject: image])
        {
          [queuedImages addObject: image];
        }
    }
  [queueCondition signal];
  [queueCondition unlock];
}

+ (NSArray *) installedLanguages
{
  [self queryInstallation];
  return cachedLanguages;
}

+ (NSString *) textFontPath
{
  [self queryInstallation];
  /* tesseract ships the glyphless font it sets its own PDF text layers in */
  return [cachedDataDirectory stringByAppendingPathComponent: @"pdf.ttf"];
}

+ (NSArray *) missingUserLanguages
{
  NSMutableArray *missing = [NSMutableArray array];

  for (NSString *identifier in [NSLocale preferredLanguages])
    {
      NSString *code = [self codeForLanguage: identifier];

      if (code != nil && ![[self installedLanguages] containsObject: code])
        {
          [missing addObject: identifier];
        }
    }
  return missing;
}

+ (NSString *) userLanguages
{
  return [self languagesForUserLanguages: [NSLocale preferredLanguages]
                               installed: [self installedLanguages]];
}

+ (BOOL) isAvailable
{
  return [[self installedLanguages] count] > 0;
}

+ (NSString *) codeForLanguage: (NSString *)identifier
{
  NSString *language = [[NSLocale componentsFromLocaleIdentifier: identifier]
                         objectForKey: NSLocaleLanguageCode];
  char iso3[16];

  if ([language length] == 0)
    {
      return nil;
    }
  /* tesseract splits Chinese by script rather than by language */
  if ([language isEqualToString: @"zh"])
    {
      return ([identifier rangeOfString: @"Hant"].location != NSNotFound
              || [identifier hasSuffix: @"TW"] || [identifier hasSuffix: @"HK"])
        ? @"chi_tra" : @"chi_sim";
    }
  /* tesseract names its data by ISO 639-2/T, which ICU knows for every language */
  strncpy(iso3, uloc_getISO3Language([language UTF8String]), sizeof(iso3) - 1);
  iso3[sizeof(iso3) - 1] = '\0';
  return iso3[0] ? [NSString stringWithUTF8String: iso3] : nil;
}

+ (NSString *) displayNameForCode: (NSString *)code
{
  NSString *language = [[code componentsSeparatedByString: @"_"] objectAtIndex: 0];
  NSString *name = [[NSLocale localeWithLocaleIdentifier: @"en"]
                     displayNameForKey: NSLocaleLanguageCode value: language];

  if (name == nil)
    {
      return code;
    }
  /* tesseract splits Chinese by script */
  if ([code hasSuffix: @"_sim"])
    {
      return [@"Simplified " stringByAppendingString: name];
    }
  if ([code hasSuffix: @"_tra"])
    {
      return [@"Traditional " stringByAppendingString: name];
    }
  return name;
}

+ (NSString *) displayNameForLanguage: (NSString *)identifier
{
  NSString *name = [[NSLocale localeWithLocaleIdentifier: @"en"]
                     displayNameForKey: NSLocaleIdentifier value: identifier];

  return name ? name : identifier;
}

+ (NSString *) languagesForUserLanguages: (NSArray *)userLanguages
                               installed: (NSArray *)installed
{
  NSMutableArray *chosen = [NSMutableArray array];

  for (NSString *identifier in userLanguages)
    {
      NSString *code = [self codeForLanguage: identifier];

      if (code != nil && [installed containsObject: code]
          && ![chosen containsObject: code])
        {
          [chosen addObject: code];
        }
    }
  if ([chosen count] == 0)
    {
      if ([installed containsObject: @"eng"])
        {
          return @"eng";
        }
      return [installed count] > 0 ? [installed objectAtIndex: 0] : nil;
    }
  return [chosen componentsJoinedByString: @"+"];
}

+ (NSArray *) wordsFromTSV: (NSString *)tsv
{
  NSMutableArray *words = [NSMutableArray array];
  NSMutableDictionary *lineNumbers = [NSMutableDictionary dictionary];

  for (NSString *row in [tsv componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [row componentsSeparatedByString: @"\t"];
      NSString *text, *lineKey;
      NSNumber *line;

      /* level page block paragraph line word left top width height conf text */
      if ([f count] < 12 || [[f objectAtIndex: 0] intValue] != 5
          || [[f objectAtIndex: 10] doubleValue] < 0)
        {
          continue;
        }
      text = [[f objectAtIndex: 11] stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([text length] == 0)
        {
          continue;
        }
      lineKey = [NSString stringWithFormat: @"%@-%@-%@", [f objectAtIndex: 2],
                          [f objectAtIndex: 3], [f objectAtIndex: 4]];
      line = [lineNumbers objectForKey: lineKey];
      if (line == nil)
        {
          line = @([lineNumbers count]);
          [lineNumbers setObject: line forKey: lineKey];
        }
      [words addObject: [[SCRecognizedWord alloc]
                          initWithText: text
                                   box: NSMakeRect([[f objectAtIndex: 6] doubleValue],
                                                   [[f objectAtIndex: 7] doubleValue],
                                                   [[f objectAtIndex: 8] doubleValue],
                                                   [[f objectAtIndex: 9] doubleValue])
                                  line: [line unsignedIntegerValue]]];
    }
  return words;
}

+ (NSArray *) recognizeWordsInImage: (SCImage *)image
                          languages: (NSString *)languages
                              error: (NSError **)error
{
  return [self recognizeWordsInImage: image languages: languages script: NULL
                               error: error];
}

/* "Latin", "Cyrillic", ... from tesseract's script detection; nil without its data */
+ (NSString *) scriptOfImageFile: (NSString *)file
{
  NSString *output = nil;

  if (SCRun([self tesseractPath], @[file, @"stdout", @"--psm", @"0"], &output, NULL) != 0)
    {
      return nil;
    }
  for (NSString *line in [output componentsSeparatedByString: @"\n"])
    {
      if ([line hasPrefix: @"Script: "])
        {
          return [[line substringFromIndex: 8] stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
        }
    }
  return nil;
}

+ (NSArray *) recognizeWordsInImage: (SCImage *)image
                          languages: (NSString *)languages
                             script: (NSString **)script
                              error: (NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *tesseract = [self tesseractPath];
  NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"Scanner-OCR-%d-%@.tiff", getpid(),
              [[NSProcessInfo processInfo] globallyUniqueString]]];
  NSString *output = nil, *errors = nil;
  int status;

  if (tesseract == nil || [languages length] == 0)
    {
      if (error)
        {
          *error = SCOCRError(@"tesseract or its language data is not installed.");
        }
      return nil;
    }
  /* TIFF carries the resolution, which tesseract needs to judge text sizes */
  if (![SCImageWriter writeImage: image toFile: file format: SCFileFormatTIFF
                         quality: 0 error: error])
    {
      return nil;
    }
  status = SCRun(tesseract, @[file, @"stdout", @"-l", languages, @"tsv"],
                 &output, &errors);
  if (script != NULL)
    {
      /* A page in another alphabet reads as nonsense; this tells which one */
      *script = [self scriptOfImageFile: file];
    }
  [fm removeItemAtPath: file error: NULL];
  if (status != 0)
    {
      if (error)
        {
          NSString *last = [[[errors stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                              componentsSeparatedByString: @"\n"] lastObject];

          *error = SCOCRError([last length] > 0 ? last : @"tesseract failed.");
        }
      return nil;
    }
  return [self wordsFromTSV: output];
}

+ (void) worker: (id)unused
{
  for (;;)
    {
      @autoreleasepool
        {
          SCImage *image;
          SCRecognition *r;
          SCImage *source;
          NSString *script = nil;
          NSUInteger generation;
          NSArray *words;
          NSError *error = nil;

          [queueCondition lock];
          while ([queuedImages count] == 0)
            {
              [queueCondition wait];
            }
          image = [queuedImages objectAtIndex: 0];
          [queuedImages removeObjectAtIndex: 0];
          r = [recognitions objectForKey: image];
          if (r == nil)
            {
              /* Forgotten while it waited in the queue */
              [queueCondition unlock];
              continue;
            }
          generation = [r generation];
          /* Kept: the page is read again when other languages get installed */
          source = [r source];
          [queueCondition unlock];

          words = [self recognizeWordsInImage: source languages: [self userLanguages]
                                       script: &script error: &error];

          [queueCondition lock];
          if ([r generation] == generation)
            {
              [r setWords: words];
              [r setScript: script];
              [r setError: error];
              [r setDone: YES];
            }
          [queueCondition broadcast];
          [queueCondition unlock];
          [self performSelectorOnMainThread: @selector(announceFinished:)
                                 withObject: image waitUntilDone: NO];
        }
    }
}

+ (void) announceFinished: (SCImage *)image
{
  [[NSNotificationCenter defaultCenter]
    postNotificationName: SCTextRecognizerDidFinishPageNotification object: image];
}

+ (NSString *) scriptForImage: (SCImage *)image
{
  NSString *script;

  if (queueCondition == nil)
    {
      return nil;
    }
  [queueCondition lock];
  script = [[recognitions objectForKey: image] script];
  [queueCondition unlock];
  return script;
}

+ (SCRecognitionState) stateForImage: (SCImage *)image
{
  SCRecognition *r;
  SCRecognitionState state = SCRecognitionNone;

  if (queueCondition == nil)
    {
      return state;
    }
  [queueCondition lock];
  r = [recognitions objectForKey: image];
  if (r != nil)
    {
      state = ![r done] ? SCRecognitionPending
        : ([r words] != nil ? SCRecognitionDone : SCRecognitionFailed);
    }
  [queueCondition unlock];
  return state;
}

+ (void) startRecognizingImage: (SCImage *)image
{
  [self startRecognizingImage: image fromImage: image];
}

+ (void) startRecognizingImage: (SCImage *)image fromImage: (SCImage *)source
{
  static BOOL workerRunning;

  if (queueCondition == nil)
    {
      queueCondition = [NSCondition new];
      queuedImages = [NSMutableArray array];
      /* Keyed by identity: SCImage does not override -isEqual: */
      recognitions = [NSMapTable strongToStrongObjectsMapTable];
    }
  [queueCondition lock];
  if ([recognitions objectForKey: image] == nil)
    {
      SCRecognition *r = [SCRecognition new];

      NSAssert([source width] == [image width] && [source height] == [image height],
               @"words are placed on the page by the source's pixels");
      [r setSource: source];
      [recognitions setObject: r forKey: image];
      [queuedImages addObject: image];
      [queueCondition signal];
    }
  if (!workerRunning)
    {
      workerRunning = YES;
      [NSThread detachNewThreadSelector: @selector(worker:) toTarget: self
                             withObject: nil];
    }
  [queueCondition unlock];
}

+ (NSArray *) wordsForImage: (SCImage *)image error: (NSError **)error
{
  SCRecognition *r = nil;

  if (queueCondition != nil)
    {
      [queueCondition lock];
      r = [recognitions objectForKey: image];
      while (r != nil && ![r done])
        {
          [queueCondition wait];
        }
      [queueCondition unlock];
    }
  if (r == nil)
    {
      return [self recognizeWordsInImage: image languages: [self userLanguages]
                                   error: error];
    }
  if ([r words] == nil && error)
    {
      *error = [r error];
    }
  return [r words];
}

+ (BOOL) writeSearchablePDFWithImages: (NSArray *)images
                               toFile: (NSString *)path
                                error: (NSError **)error
{
  NSMutableArray *words = [NSMutableArray array];

  for (SCImage *image in images)
    {
      NSArray *w = [self wordsForImage: image error: error];

      if (w == nil)
        {
          return NO;
        }
      [words addObject: w];
    }
  return [SCPDFWriter writePDFWithImages: images words: words
                                textFont: [self textFontPath]
                                  toFile: path error: error];
}

@end
