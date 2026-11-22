/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCFax.h"
#import "SCImage.h"
#import "SCImageBuilder.h"
#include <tiffio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static NSError *
SCFaxError(NSString *path, NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 3
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Could not save \"%@\": %@",
                                         [path lastPathComponent], reason]}];
}

BOOL
SCWriteG4TIFF(SCImage *image, NSString *path, NSError **error)
{
  TIFF *tif;
  NSUInteger y, bpr = [image bytesPerRow];
  const uint8_t *bits = [[image pixels] bytes];
  BOOL ok = YES;

  NSCAssert([image bitsPerSample] == 1, @"G4 needs a 1-bit image");
  tif = TIFFOpen([path fileSystemRepresentation], "w");
  if (tif == NULL)
    {
      if (error)
        {
          *error = SCFaxError(path, @"the file could not be created.");
        }
      return NO;
    }
  TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, (uint32_t)[image width]);
  TIFFSetField(tif, TIFFTAG_IMAGELENGTH, (uint32_t)[image height]);
  TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 1);
  TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 1);
  /* Our bits are 1 for black, which is what MinIsWhite means */
  TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISWHITE);
  TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_CCITTFAX4);
  TIFFSetField(tif, TIFFTAG_FILLORDER, FILLORDER_MSB2LSB);
  TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  /* One strip, so the strip is the bare G4 stream SCG4Data needs */
  TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, (uint32_t)[image height]);
  if ([image resolution] > 0)
    {
      TIFFSetField(tif, TIFFTAG_XRESOLUTION, (float)[image resolution]);
      TIFFSetField(tif, TIFFTAG_YRESOLUTION, (float)[image resolution]);
      TIFFSetField(tif, TIFFTAG_RESOLUTIONUNIT, RESUNIT_INCH);
    }
  for (y = 0; y < [image height] && ok; y++)
    {
      ok = TIFFWriteScanline(tif, (void *)(bits + y * bpr), (uint32_t)y, 0) == 1;
    }
  TIFFClose(tif);
  if (!ok)
    {
      [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
      if (error)
        {
          *error = SCFaxError(path, @"the image could not be compressed.");
        }
      return NO;
    }
  return YES;
}

NSData *
SCG4Data(SCImage *image, NSError **error)
{
  NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"Scanner-G4-%d-%@.tiff", getpid(),
              [[NSProcessInfo processInfo] globallyUniqueString]]];
  NSMutableData *data = nil;
  TIFF *tif;

  /* libtiff only encodes into a TIFF; the strip is taken out of a temporary one */
  if (!SCWriteG4TIFF(image, temp, error))
    {
      return nil;
    }
  tif = TIFFOpen([temp fileSystemRepresentation], "r");
  if (tif != NULL && TIFFNumberOfStrips(tif) == 1)
    {
      tmsize_t size = TIFFRawStripSize(tif, 0);

      if (size > 0)
        {
          data = [NSMutableData dataWithLength: size];
          if (TIFFReadRawStrip(tif, 0, [data mutableBytes], size) != size)
            {
              data = nil;
            }
        }
    }
  if (tif != NULL)
    {
      TIFFClose(tif);
    }
  [[NSFileManager defaultManager] removeItemAtPath: temp error: NULL];
  if (data == nil && error)
    {
      *error = SCFaxError(temp, @"the compressed image could not be read back.");
    }
  return data;
}

static NSError *
SCReadError(NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 3
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Could not read the scanned page: %@", reason]}];
}

SCImage *
SCImageFromTIFFData(NSData *data, NSError **error)
{
  NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"Scanner-in-%d-%@.tiff", getpid(),
              [[NSProcessInfo processInfo] globallyUniqueString]]];
  uint32_t width = 0, height = 0, y;
  uint16_t bps = 0, spp = 0, photometric = PHOTOMETRIC_MINISBLACK, planar = PLANARCONFIG_CONTIG;
  uint16_t unit = RESUNIT_INCH, compression = COMPRESSION_NONE;
  float xres = 0;
  NSMutableData *pixels;
  NSUInteger outRow;
  TIFF *tif;
  BOOL ok = YES;

  /* libtiff reads files; the data is small enough for a round trip */
  if (![data writeToFile: temp atomically: NO])
    {
      if (error)
        {
          *error = SCReadError(@"it could not be stored for reading.");
        }
      return nil;
    }
  tif = TIFFOpen([temp fileSystemRepresentation], "r");
  [[NSFileManager defaultManager] removeItemAtPath: temp error: NULL];
  if (tif == NULL)
    {
      if (error)
        {
          *error = SCReadError(@"the printer sent no TIFF image.");
        }
      return nil;
    }
  TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &width);
  TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &height);
  TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &bps);
  TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &spp);
  TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &planar);
  TIFFGetField(tif, TIFFTAG_PHOTOMETRIC, &photometric);
  TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &compression);
  /* Color TIFF-JPEG is stored as YCbCr; the codec converts it when asked to */
  if (compression == COMPRESSION_JPEG && photometric == PHOTOMETRIC_YCBCR)
    {
      TIFFSetField(tif, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB);
      photometric = PHOTOMETRIC_RGB;
    }
  TIFFGetField(tif, TIFFTAG_XRESOLUTION, &xres);
  TIFFGetFieldDefaulted(tif, TIFFTAG_RESOLUTIONUNIT, &unit);
  if (unit == RESUNIT_CENTIMETER)
    {
      xres *= 2.54f;
    }

  if (width == 0 || height == 0 || planar != PLANARCONFIG_CONTIG
      || !((spp == 1 && (bps == 1 || bps == 8 || bps == 16)
            && (photometric == PHOTOMETRIC_MINISBLACK || photometric == PHOTOMETRIC_MINISWHITE))
           || (spp == 3 && (bps == 8 || bps == 16) && photometric == PHOTOMETRIC_RGB)))
    {
      TIFFClose(tif);
      if (error)
        {
          *error = SCReadError(@"the printer sent an image layout Scanner cannot read.");
        }
      return nil;
    }
  outRow = (bps == 1) ? (width + 7) / 8 : (NSUInteger)width * spp * (bps / 8);
  pixels = [NSMutableData dataWithLength: outRow * height];
  {
    tmsize_t lineSize = TIFFScanlineSize(tif);
    uint8_t *line = malloc(lineSize > (tmsize_t)outRow ? lineSize : outRow);

    for (y = 0; y < height && ok; y++)
      {
        uint8_t *dst = (uint8_t *)[pixels mutableBytes] + y * outRow;
        NSUInteger i;

        ok = TIFFReadScanline(tif, line, y, 0) == 1;
        memcpy(dst, line, outRow);
        /* Scanner's 1-bit pages use 1 for black, 8-bit ones 0 for black */
        if (bps == 1 && photometric == PHOTOMETRIC_MINISBLACK)
          {
            for (i = 0; i < outRow; i++)
              {
                dst[i] = ~dst[i];
              }
          }
        /* Bits past the right edge are undefined after decoding; keep them clear */
        if (bps == 1 && width % 8 != 0)
          {
            dst[outRow - 1] &= (uint8_t)(0xff << (8 - width % 8));
          }
        else if (bps == 8 && spp == 1 && photometric == PHOTOMETRIC_MINISWHITE)
          {
            for (i = 0; i < outRow; i++)
              {
                dst[i] = 255 - dst[i];
              }
          }
      }
    free(line);
  }
  TIFFClose(tif);
  if (!ok)
    {
      if (error)
        {
          *error = SCReadError(@"it is incomplete.");
        }
      return nil;
    }
  return [[SCImage alloc] initWithWidth: width height: height samplesPerPixel: spp
                          bitsPerSample: bps pixels: pixels resolution: xres];
}
