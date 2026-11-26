/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCSaver.h"
#import "SCPreferences.h"
#import "SCImageWriter.h"
#import "SCFileNamer.h"
#import "SCTextRecognizer.h"

@interface SCSaver (Announcing)
+ (void) announcePaths: (NSArray *)paths;
@end

/* Carries one text recognition job to its worker thread and back */
@interface SCRecognitionJob : NSObject
@property (nonatomic, copy) NSArray *images;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) SCSaveCompletion completion;
@property (nonatomic, strong) NSError *error;
@property (nonatomic) BOOL succeeded;
@end

@implementation SCRecognitionJob

- (void) run: (id)unused
{
  @autoreleasepool
    {
      NSError *error = nil;

      _succeeded = [SCTextRecognizer writeSearchablePDFWithImages: _images
                                                           toFile: _path
                                                            error: &error];
      _error = error;
      [self performSelectorOnMainThread: @selector(finish:) withObject: nil
                          waitUntilDone: NO];
    }
}

- (void) finish: (id)unused
{
  if (_succeeded)
    {
      [SCSaver announcePaths: @[_path]];
    }
  if (!_succeeded)
    {
      /* The placeholder that reserved the name must not stay as an empty file */
      [[NSFileManager defaultManager] removeItemAtPath: _path error: NULL];
    }
  _completion(_succeeded ? @[_path] : nil, _error);
}

@end

NSString * const SCSaverDidSaveNotification = @"SCSaverDidSaveNotification";

@implementation SCSaver

+ (BOOL) recognizesTextForFormat: (SCFileFormat)format
{
  return format == SCFileFormatPDF
    && [[NSUserDefaults standardUserDefaults] boolForKey: SCRecognizeTextKey]
    && [SCTextRecognizer isAvailable];
}

+ (void) writeImages: (NSArray *)images format: (SCFileFormat)format
           pathMaker: (NSString * (^)(void))nextPath
          completion: (SCSaveCompletion)completion
{
  double quality = [[NSUserDefaults standardUserDefaults] doubleForKey: SCJPEGQualityKey];
  NSMutableArray *written = [NSMutableArray array];
  NSError *error = nil;

  if ([self recognizesTextForFormat: format])
    {
      SCRecognitionJob *job = [SCRecognitionJob new];

      [job setImages: images];
      [job setPath: nextPath()];
      [job setCompletion: completion];
      /* Reserves the name, so a save started meanwhile takes the next number */
      [[NSData data] writeToFile: [job path] atomically: NO];
      [NSThread detachNewThreadSelector: @selector(run:) toTarget: job
                             withObject: nil];
      return;
    }

  if (format == SCFileFormatPDF)
    {
      NSString *path = nextPath();

      if ([SCImageWriter writePDFWithImages: images toFile: path error: &error])
        {
          [written addObject: path];
        }
    }
  else
    {
      for (id image in images)
        {
          NSString *path = nextPath();

          if (![SCImageWriter writeImage: image toFile: path format: format
                                 quality: quality error: &error])
            {
              break;
            }
          [written addObject: path];
        }
    }
  if (error == nil)
    {
      [self announcePaths: written];
    }
  completion(error ? nil : written, error);
}

+ (void) announcePaths: (NSArray *)paths
{
  [[NSNotificationCenter defaultCenter]
    postNotificationName: SCSaverDidSaveNotification object: self
                userInfo: @{@"paths": paths}];
}

+ (void) saveImages: (NSArray *)images format: (SCFileFormat)format
         completion: (SCSaveCompletion)completion
{
  NSString *dir = [SCPreferences saveDirectory];
  NSError *error = nil;
  SCFileNamer *namer;

  if (![[NSFileManager defaultManager] createDirectoryAtPath: dir
                                 withIntermediateDirectories: YES
                                                  attributes: nil error: &error])
    {
      completion(nil, error);
      return;
    }
  namer = [[SCFileNamer alloc]
            initWithDirectory: dir
                      pattern: [[NSUserDefaults standardUserDefaults]
                                 stringForKey: SCFileNamePatternKey]
                    extension: [SCImageWriter extensionForFormat: format]];
  [self writeImages: images format: format
          pathMaker: ^NSString *{ return [namer nextPath]; }
         completion: completion];
}

+ (void) saveImages: (NSArray *)images toPath: (NSString *)path
         completion: (SCSaveCompletion)completion
{
  SCFileFormat format = [SCImageWriter formatForExtension: [path pathExtension]];
  NSString *base = [path stringByDeletingPathExtension];
  NSString *ext = [path pathExtension];
  __block NSUInteger page = 0;

  if ([ext length] == 0)
    {
      format = [SCPreferences fileFormat];
      ext = [SCImageWriter extensionForFormat: format];
    }
  [self writeImages: images format: format pathMaker: ^NSString *{
      page++;
      /* Further pages of a one-page format get numbered after the chosen name */
      if (page == 1)
        {
          return [base stringByAppendingPathExtension: ext];
        }
      return [[base stringByAppendingFormat: @"-%lu", (unsigned long)page]
               stringByAppendingPathExtension: ext];
    } completion: completion];
}

@end
