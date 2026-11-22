/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_ImageBuilder - assembling SANE frames into images, and naming files. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCImage.h"
#import "SCImageBuilder.h"
#import "SCFileNamer.h"

static SANE_Parameters
Params(SANE_Frame format, int depth, int ppl, int bpl, int lines, BOOL last)
{
  SANE_Parameters p;

  p.format = format;
  p.depth = depth;
  p.pixels_per_line = ppl;
  p.bytes_per_line = bpl;
  p.lines = lines;
  p.last_frame = last ? SANE_TRUE : SANE_FALSE;
  return p;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("gray line art")
    {
      /* 10 pixels per line need 2 bytes; bit 1 is black in SANE */
      SCImageBuilder *b = [[SCImageBuilder new] autorelease];
      SANE_Parameters p = Params(SANE_FRAME_GRAY, 1, 10, 2, 2, YES);
      uint8_t rows[4] = {0x80, 0x40, 0x00, 0xff};
      const uint8_t *px;
      SCImage *img;

      PASS([b beginFrameWithParameters: &p error: NULL], "frame accepted");
      [b appendBytes: rows length: 4];
      [b endFrame];
      PASS([b isComplete], "last frame completes the page");
      img = [b imageWithResolution: 300 error: NULL];
      PASS([img width] == 10 && [img height] == 2, "size taken from parameters");
      PASS([img bitsPerSample] == 1 && [img samplesPerPixel] == 1
           && [img bytesPerRow] == 2, "line art stays 1-bit with byte-padded rows");
      px = [[img pixels] bytes];
      PASS(px[0] == 0x80 && px[3] == 0xff, "bits are kept, 1 is black");
      px = [[[img eightBitImage] pixels] bytes];
      PASS(px[0] == 0 && px[1] == 255, "8-bit expansion: set bit is black");
      PASS(px[9] == 0 && px[10] == 255, "padding bits of a row are skipped");
      PASS([img resolution] == 300, "resolution is kept");
    }
  END_SET("gray line art")

  START_SET("unknown line count and row padding")
    {
      SCImageBuilder *b = [[SCImageBuilder new] autorelease];
      /* 3 gray pixels in 4-byte rows; lines unknown (-1) as hand scanners do */
      SANE_Parameters p = Params(SANE_FRAME_GRAY, 8, 3, 4, -1, YES);
      uint8_t rows[10] = {1, 2, 3, 99, 4, 5, 6, 99, 7, 8};
      const uint8_t *px;
      SCImage *img;

      [b beginFrameWithParameters: &p error: NULL];
      [b appendBytes: rows length: 3];
      [b appendBytes: rows + 3 length: 7];
      [b endFrame];
      img = [b imageWithResolution: 0 error: NULL];
      PASS([img height] == 2, "rows counted from bytes, partial row dropped");
      px = [[img pixels] bytes];
      PASS(px[2] == 3 && px[3] == 4, "row padding byte is not copied");
    }
  END_SET("unknown line count and row padding")

  START_SET("16-bit RGB")
    {
      SCImageBuilder *b = [[SCImageBuilder new] autorelease];
      SANE_Parameters p = Params(SANE_FRAME_RGB, 16, 1, 6, 1, YES);
      uint16_t px[3] = {0x1234, 0xabcd, 0xffff};
      SCImage *img, *eight;

      [b beginFrameWithParameters: &p error: NULL];
      [b appendBytes: px length: 6];
      [b endFrame];
      img = [b imageWithResolution: 0 error: NULL];
      PASS([img bitsPerSample] == 16 && [img samplesPerPixel] == 3, "16-bit RGB kept");
      PASS(((const uint16_t *)[[img pixels] bytes])[1] == 0xabcd,
           "16-bit samples stay in host order");
      eight = [img eightBitImage];
      PASS(((const uint8_t *)[[eight pixels] bytes])[1] == 0xab,
           "8-bit conversion keeps the high byte");
      PASS(((const uint16_t *)[[[img invertedImage] pixels] bytes])[2] == 0,
           "inverting white gives black");
    }
  END_SET("16-bit RGB")

  START_SET("black and white")
    {
      /* gray 10, 200, 127, 128 in one row; RGB pixel: pure blue is dark, green light */
      uint8_t g[4] = {10, 200, 127, 128};
      uint8_t rgb[6] = {0, 0, 255, 0, 255, 0};
      SCImage *gray = [[[SCImage alloc]
                         initWithWidth: 4 height: 1 samplesPerPixel: 1 bitsPerSample: 8
                                pixels: [NSData dataWithBytes: g length: 4]
                            resolution: 300] autorelease];
      SCImage *color = [[[SCImage alloc]
                          initWithWidth: 2 height: 1 samplesPerPixel: 3 bitsPerSample: 8
                                 pixels: [NSData dataWithBytes: rgb length: 6]
                             resolution: 0] autorelease];
      SCImage *bw = [gray blackAndWhiteImageWithThreshold: 128];
      const uint8_t *px = [[bw pixels] bytes];

      PASS([bw bitsPerSample] == 1 && [bw resolution] == 300, "threshold gives 1-bit");
      PASS(px[0] == 0xa0, "darker than the threshold is black, equal is white");
      px = [[[color blackAndWhiteImageWithThreshold: 128] pixels] bytes];
      PASS(px[0] == 0x80, "color uses luma: blue is dark, green is light");
      PASS([[bw invertedImage] bitsPerSample] == 1
           && (((const uint8_t *)[[[bw invertedImage] pixels] bytes])[0] & 0xf0) == 0x50,
           "inverting a 1-bit image flips its bits");
    }
  END_SET("black and white")

  START_SET("three-pass color")
    {
      SCImageBuilder *b = [[SCImageBuilder new] autorelease];
      SANE_Frame f[3] = {SANE_FRAME_GREEN, SANE_FRAME_BLUE, SANE_FRAME_RED};
      uint8_t v[3] = {20, 30, 10};
      const uint8_t *px;
      SCImage *img;
      int i;

      /* Frames may arrive in any order; the last one says so */
      for (i = 0; i < 3; i++)
        {
          SANE_Parameters p = Params(f[i], 8, 2, 2, 1, i == 2);
          uint8_t row[2] = {v[i], v[i]};

          [b beginFrameWithParameters: &p error: NULL];
          PASS(i == 0 || ![b isComplete], "not complete before the last pass");
          [b appendBytes: row length: 2];
          [b endFrame];
        }
      img = [b imageWithResolution: 0 error: NULL];
      px = [[img pixels] bytes];
      PASS([img samplesPerPixel] == 3, "passes combine into RGB");
      PASS(px[0] == 10 && px[1] == 20 && px[2] == 30, "channels land in R, G, B order");
    }
  END_SET("three-pass color")

  START_SET("incomplete page")
    {
      SCImageBuilder *b = [[SCImageBuilder new] autorelease];
      SANE_Parameters p = Params(SANE_FRAME_RED, 8, 1, 1, 1, NO);
      uint8_t x = 1;
      NSError *error = nil;

      [b beginFrameWithParameters: &p error: NULL];
      [b appendBytes: &x length: 1];
      [b endFrame];
      PASS([b imageWithResolution: 0 error: &error] == nil && error != nil,
           "a page without its last frame is an error");
      p = Params(SANE_FRAME_GRAY, 4, 1, 1, 1, YES);
      PASS(![b beginFrameWithParameters: &p error: NULL], "depth 4 is refused");
    }
  END_SET("incomplete page")

  START_SET("file names")
    {
      NSFileManager *fm = [NSFileManager defaultManager];
      NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat: @"t_FileNamer-%d", getpid()]];
      SCFileNamer *n;
      NSString *path;

      [fm removeItemAtPath: dir error: NULL];
      [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                     attributes: nil error: NULL];

      n = [[[SCFileNamer alloc] initWithDirectory: dir pattern: @"Scan-###"
                                        extension: @"png"] autorelease];
      PASS_EQUAL([[n nextPath] lastPathComponent], @"Scan-001.png",
                 "first number is 1, padded to the pattern");
      [@"x" writeToFile: [dir stringByAppendingPathComponent: @"Scan-041.png"]
             atomically: NO encoding: NSUTF8StringEncoding error: NULL];
      [@"x" writeToFile: [dir stringByAppendingPathComponent: @"Scan-099.jpg"]
             atomically: NO encoding: NSUTF8StringEncoding error: NULL];
      [@"x" writeToFile: [dir stringByAppendingPathComponent: @"Scan-0x9.png"]
             atomically: NO encoding: NSUTF8StringEncoding error: NULL];
      path = [n nextPath];
      PASS_EQUAL([path lastPathComponent], @"Scan-042.png",
                 "continues after the highest number with the same extension");
      PASS_EQUAL([[n nextPath] lastPathComponent], @"Scan-043.png",
                 "consecutive calls never repeat a number");

      n = [[[SCFileNamer alloc] initWithDirectory: dir pattern: @"Receipt"
                                        extension: @"pdf"] autorelease];
      PASS_EQUAL([[n nextPath] lastPathComponent], @"Receipt-0001.pdf",
                 "pattern without # gets a number appended");

      [fm removeItemAtPath: dir error: NULL];
    }
  END_SET("file names")

  [arp release];
  return 0;
}
