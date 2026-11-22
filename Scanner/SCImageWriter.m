/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCImageWriter.h"
#import "SCImage.h"
#import "SCImageBuilder.h"
#import "SCFax.h"
#import "SCPDFWriter.h"
#include <string.h>

static NSError *
SCWriteError(NSString *path, NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 2
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Could not save \"%@\": %@",
                                         [path lastPathComponent], reason]}];
}

/* Scanners without a resolution option still need a sensible page size */
static double
SCEffectiveResolution(SCImage *image)
{
  return [image resolution] > 0 ? [image resolution] : 72.0;
}

@implementation SCImageWriter

+ (NSArray *) formatNames
{
  return @[@"PNG", @"JPEG", @"TIFF", @"PDF"];
}

+ (NSString *) extensionForFormat: (SCFileFormat)format
{
  switch (format)
    {
      case SCFileFormatJPEG: return @"jpg";
      case SCFileFormatTIFF: return @"tiff";
      case SCFileFormatPDF:  return @"pdf";
      default:               return @"png";
    }
}

+ (SCFileFormat) formatForExtension: (NSString *)extension
{
  NSString *e = [extension lowercaseString];

  if ([e isEqualToString: @"jpg"] || [e isEqualToString: @"jpeg"])
    {
      return SCFileFormatJPEG;
    }
  if ([e isEqualToString: @"tif"] || [e isEqualToString: @"tiff"])
    {
      return SCFileFormatTIFF;
    }
  if ([e isEqualToString: @"pdf"])
    {
      return SCFileFormatPDF;
    }
  return SCFileFormatPNG;
}

+ (NSBitmapImageRep *) bitmapForImage: (SCImage *)image
{
  NSUInteger spp = [image samplesPerPixel];
  NSUInteger bps = [image bitsPerSample];
  double scale = 72.0 / SCEffectiveResolution(image);
  NSBitmapImageRep *rep;

  rep = [[NSBitmapImageRep alloc]
          initWithBitmapDataPlanes: NULL
                        pixelsWide: [image width]
                        pixelsHigh: [image height]
                     bitsPerSample: bps
                   samplesPerPixel: spp
                          hasAlpha: NO
                          isPlanar: NO
                    colorSpaceName: (spp == 1) ? NSDeviceWhiteColorSpace
                                               : NSDeviceRGBColorSpace
                       bytesPerRow: [image bytesPerRow]
                      bitsPerPixel: bps * spp];
  if (bps == 1)
    {
      /* In a white color space 1 is white; our 1-bit images use 1 for black */
      const uint8_t *src = [[image pixels] bytes];
      uint8_t *dst = [rep bitmapData];
      NSUInteger i, n = [[image pixels] length];

      for (i = 0; i < n; i++)
        {
          dst[i] = ~src[i];
        }
    }
  else
    {
      memcpy([rep bitmapData], [[image pixels] bytes], [[image pixels] length]);
    }
  [rep setSize: NSMakeSize([image width] * scale, [image height] * scale)];
  return rep;
}

+ (BOOL) writeImage: (SCImage *)image toFile: (NSString *)path
             format: (SCFileFormat)format quality: (double)quality
              error: (NSError **)error
{
  NSBitmapImageRep *rep;
  NSData *data;

  switch (format)
    {
      case SCFileFormatPDF:
        return [self writePDFWithImages: @[image] toFile: path error: error];
      case SCFileFormatJPEG:
        /* JPEG has no 16-bit samples */
        rep = [self bitmapForImage: [image eightBitImage]];
        data = [rep representationUsingType: NSJPEGFileType
                                 properties: @{NSImageCompressionFactor:
                                                 @(quality)}];
        break;
      case SCFileFormatTIFF:
        if ([image bitsPerSample] == 1)
          {
            return SCWriteG4TIFF(image, path, error);
          }
        rep = [self bitmapForImage: image];
        data = [rep TIFFRepresentationUsingCompression: NSTIFFCompressionLZW
                                                factor: 0];
        break;
      default:
        rep = [self bitmapForImage: image];
        data = [rep representationUsingType: NSPNGFileType properties: @{}];
        break;
    }
  if (data == nil)
    {
      if (error)
        {
          *error = SCWriteError(path, @"the image could not be encoded.");
        }
      return NO;
    }
  return [data writeToFile: path options: NSDataWritingAtomic error: error];
}

+ (BOOL) writePDFWithImages: (NSArray *)images toFile: (NSString *)path
                      error: (NSError **)error
{
  return [SCPDFWriter writePDFWithImages: images words: nil textFont: nil
                                  toFile: path error: error];
}

@end
