/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class SCImage;

typedef NS_ENUM(NSInteger, SCFileFormat)
{
  SCFileFormatPNG,
  SCFileFormatJPEG,
  SCFileFormatTIFF,
  SCFileFormatPDF
};

@interface SCImageWriter : NSObject

+ (NSArray *) formatNames;
+ (NSString *) extensionForFormat: (SCFileFormat)format;
+ (SCFileFormat) formatForExtension: (NSString *)extension;

/* Physical size follows the scan resolution, so prints come out 1:1 */
+ (NSBitmapImageRep *) bitmapForImage: (SCImage *)image;

/* quality 0..1, used for JPEG only */
+ (BOOL) writeImage: (SCImage *)image toFile: (NSString *)path
             format: (SCFileFormat)format quality: (double)quality
              error: (NSError **)error;

/* One page per image */
+ (BOOL) writePDFWithImages: (NSArray *)images toFile: (NSString *)path
                      error: (NSError **)error;

@end
