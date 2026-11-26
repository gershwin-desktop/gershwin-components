/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_ImageWriter - saving scans as PNG, JPEG, TIFF and multi-page PDF. Headless. */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "SCImage.h"
#import "SCImageWriter.h"
#include <tiffio.h>

static SCImage *
Image(NSUInteger w, NSUInteger h, NSUInteger spp, NSUInteger bps, double dpi)
{
  NSMutableData *d = [NSMutableData dataWithLength: w * h * spp * bps / 8];
  uint8_t *p = [d mutableBytes];
  NSUInteger i;

  for (i = 0; i < [d length]; i++)
    {
      p[i] = i * 7;
    }
  return [[[SCImage alloc] initWithWidth: w height: h samplesPerPixel: spp
                           bitsPerSample: bps pixels: d resolution: dpi]
           autorelease];
}

static NSBitmapImageRep *
ReadBack(NSString *path)
{
  return (NSBitmapImageRep *)[NSBitmapImageRep imageRepWithContentsOfFile: path];
}

/* Needs pdfinfo and pdfimages from poppler-utils */
static NSString *
Poppler(NSArray *arguments)
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

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_ImageWriter-%d", getpid()]];
  NSString *path;
  NSBitmapImageRep *rep;
  NSError *error = nil;

  [fm removeItemAtPath: dir error: NULL];
  [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                 attributes: nil error: NULL];

  PASS([SCImageWriter formatForExtension: @"JPEG"] == SCFileFormatJPEG
       && [[SCImageWriter extensionForFormat: SCFileFormatTIFF]
            isEqualToString: @"tiff"], "extensions map to formats");

  rep = [SCImageWriter bitmapForImage: Image(300, 150, 1, 8, 300)];
  PASS(NSEqualSizes([rep size], NSMakeSize(72, 36)),
       "bitmap size in points follows the resolution");

  path = [dir stringByAppendingPathComponent: @"gray.png"];
  PASS([SCImageWriter writeImage: Image(31, 17, 1, 8, 150) toFile: path
                          format: SCFileFormatPNG quality: 0 error: &error],
       "8-bit gray PNG is written");
  rep = ReadBack(path);
  PASS([rep pixelsWide] == 31 && [rep pixelsHigh] == 17
       && [rep samplesPerPixel] == 1, "gray PNG reads back with its size");

  path = [dir stringByAppendingPathComponent: @"deep.tiff"];
  PASS([SCImageWriter writeImage: Image(20, 10, 3, 16, 300) toFile: path
                          format: SCFileFormatTIFF quality: 0 error: &error],
       "16-bit RGB TIFF is written");
  rep = ReadBack(path);
  PASS([rep bitsPerSample] == 16 && [rep samplesPerPixel] == 3,
       "TIFF keeps 16 bits per sample");

  path = [dir stringByAppendingPathComponent: @"deep.png"];
  PASS([SCImageWriter writeImage: Image(20, 10, 3, 16, 300) toFile: path
                          format: SCFileFormatPNG quality: 0 error: &error],
       "16-bit RGB PNG is written");
  rep = ReadBack(path);
  PASS([rep pixelsWide] == 20 && [rep bitsPerSample] == 16,
       "PNG keeps 16 bits per sample");

  path = [dir stringByAppendingPathComponent: @"photo.jpg"];
  PASS([SCImageWriter writeImage: Image(40, 30, 3, 16, 300) toFile: path
                          format: SCFileFormatJPEG quality: 0.8 error: &error],
       "JPEG is written from 16-bit data");
  rep = ReadBack(path);
  PASS([rep pixelsWide] == 40 && [rep bitsPerSample] == 8,
       "JPEG reads back as 8-bit");

  path = [dir stringByAppendingPathComponent: @"pages.pdf"];
  {
    NSArray *pages = [NSArray arrayWithObjects: Image(60, 80, 1, 8, 100),
                              Image(80, 60, 3, 16, 200), nil];
    NSString *text;
    NSString *info;

    PASS([SCImageWriter writePDFWithImages: pages toFile: path error: &error],
         "two-page PDF is written");
    text = [[[NSString alloc] initWithData: [NSData dataWithContentsOfFile: path]
                                  encoding: NSISOLatin1StringEncoding] autorelease];
    PASS([text hasPrefix: @"%PDF"], "file is a PDF");
    /* cairo packs page dictionaries into compressed object streams, so ask poppler */
    info = Poppler([NSArray arrayWithObjects: @"pdfinfo", path, nil]);
    PASS([info rangeOfString: @"Pages:           2"].location != NSNotFound,
         "PDF has two pages");
    PASS([info rangeOfString: @"Page size:       43.2 x 57.6 pts"].location
         != NSNotFound, "first page size follows its resolution");
    PASS(![fm fileExistsAtPath: [path stringByAppendingString: @".part"]],
         "no temporary file is left behind");
  }

  START_SET("black and white")
    {
      /* A black square on white, 1 is black */
      NSUInteger w = 200, h = 100, bpr = (w + 7) / 8, x, y;
      NSMutableData *d = [NSMutableData dataWithLength: bpr * h];
      uint8_t *p = [d mutableBytes];
      SCImage *bw;
      NSColor *c;
      TIFF *tif;
      uint16_t compression = 0, bits = 0;
      NSDictionary *attrs;
      NSString *list;
      NSArray *pages;

      for (y = 20; y < 60; y++)
        {
          for (x = 40; x < 80; x++)
            {
              p[y * bpr + x / 8] |= 0x80 >> (x % 8);
            }
        }
      bw = [[[SCImage alloc] initWithWidth: w height: h samplesPerPixel: 1
                             bitsPerSample: 1 pixels: d resolution: 300]
             autorelease];

      path = [dir stringByAppendingPathComponent: @"bw.tiff"];
      PASS([SCImageWriter writeImage: bw toFile: path format: SCFileFormatTIFF
                             quality: 0 error: &error], "1-bit TIFF is written");
      tif = TIFFOpen([path fileSystemRepresentation], "r");
      TIFFGetField(tif, TIFFTAG_COMPRESSION, &compression);
      TIFFGetField(tif, TIFFTAG_BITSPERSAMPLE, &bits);
      TIFFClose(tif);
      PASS(compression == COMPRESSION_CCITTFAX4 && bits == 1,
           "1-bit TIFF is CCITT G4 compressed");
      attrs = [fm attributesOfItemAtPath: path error: NULL];
      PASS([attrs fileSize] < 600, "G4 keeps a simple page tiny");
      rep = ReadBack(path);
      c = [[rep colorAtX: 50 y: 30] colorUsingColorSpaceName: NSCalibratedWhiteColorSpace];
      PASS([c whiteComponent] < 0.1, "black stays black in the TIFF");
      c = [[rep colorAtX: 5 y: 5] colorUsingColorSpaceName: NSCalibratedWhiteColorSpace];
      PASS([c whiteComponent] > 0.9, "white stays white in the TIFF");

      path = [dir stringByAppendingPathComponent: @"bw.png"];
      PASS([SCImageWriter writeImage: bw toFile: path format: SCFileFormatPNG
                             quality: 0 error: &error], "1-bit PNG is written");
      rep = ReadBack(path);
      c = [[rep colorAtX: 50 y: 30] colorUsingColorSpaceName: NSCalibratedWhiteColorSpace];
      PASS([rep bitsPerSample] == 1 && [c whiteComponent] < 0.1,
           "PNG keeps 1 bit and black stays black");

      path = [dir stringByAppendingPathComponent: @"bw.jpg"];
      PASS([SCImageWriter writeImage: bw toFile: path format: SCFileFormatJPEG
                             quality: 0.9 error: &error]
           && [ReadBack(path) bitsPerSample] == 8, "JPEG gets 8-bit gray");

      path = [dir stringByAppendingPathComponent: @"bw.pdf"];
      pages = [NSArray arrayWithObjects: bw, Image(60, 80, 1, 8, 100), nil];
      PASS([SCImageWriter writePDFWithImages: pages toFile: path error: &error],
           "PDF with a 1-bit page is written");
      list = Poppler([NSArray arrayWithObjects: @"pdfimages", @"-list", path, nil]);
      PASS([list rangeOfString: @"ccitt"].location != NSNotFound,
           "1-bit page is embedded CCITT compressed");
      /* Rendered at the scan resolution, page pixels are image pixels */
      Poppler([NSArray arrayWithObjects: @"pdftoppm", @"-png", @"-r", @"300",
                       @"-f", @"1", @"-l", @"1", @"-singlefile", path,
                       [dir stringByAppendingPathComponent: @"render"], nil]);
      rep = ReadBack([dir stringByAppendingPathComponent: @"render.png"]);
      c = [[rep colorAtX: 50 y: 30] colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
      PASS(rep != nil && [c redComponent] < 0.1, "fax page renders black as black");
      c = [[rep colorAtX: 5 y: 5] colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
      PASS([c redComponent] > 0.9, "fax page renders white as white");
    }
  END_SET("black and white")

  [fm removeItemAtPath: dir error: NULL];
  [arp release];
  return 0;
}
