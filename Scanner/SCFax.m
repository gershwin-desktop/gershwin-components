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
