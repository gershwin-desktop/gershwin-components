/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCImage.h"

@implementation SCImage

- (instancetype) initWithWidth: (NSUInteger)width
                        height: (NSUInteger)height
               samplesPerPixel: (NSUInteger)spp
                 bitsPerSample: (NSUInteger)bps
                        pixels: (NSData *)pixels
                    resolution: (double)dpi
{
  self = [super init];
  if (self)
    {
      NSParameterAssert(spp == 1 || spp == 3);
      NSParameterAssert(bps == 8 || bps == 16 || (bps == 1 && spp == 1));
      _width = width;
      _height = height;
      _samplesPerPixel = spp;
      _bitsPerSample = bps;
      _pixels = [pixels copy];
      _resolution = dpi;
      NSParameterAssert([pixels length] == [self bytesPerRow] * height);
    }
  return self;
}

- (NSUInteger) bytesPerRow
{
  if (_bitsPerSample == 1)
    {
      return (_width + 7) / 8;
    }
  return _width * _samplesPerPixel * (_bitsPerSample / 8);
}

- (SCImage *) imageWithResolution: (double)dpi
{
  return [[SCImage alloc] initWithWidth: _width height: _height
                        samplesPerPixel: _samplesPerPixel
                          bitsPerSample: _bitsPerSample
                                 pixels: _pixels resolution: dpi];
}

- (SCImage *) invertedImage
{
  NSMutableData *out = [_pixels mutableCopy];
  uint8_t *p = [out mutableBytes];
  NSUInteger n = [out length];
  NSUInteger i;

  /*
   * Inverting every byte is correct for 16-bit samples too, in either byte
   * order, and for 1-bit rows, whose padding bits nobody reads
   */
  for (i = 0; i < n; i++)
    {
      p[i] = 255 - p[i];
    }
  return [[SCImage alloc] initWithWidth: _width height: _height
                        samplesPerPixel: _samplesPerPixel
                          bitsPerSample: _bitsPerSample
                                 pixels: out resolution: _resolution];
}

- (SCImage *) eightBitImage
{
  NSUInteger count, i;
  const uint16_t *src;
  NSMutableData *out;
  uint8_t *dst;

  if (_bitsPerSample == 8)
    {
      return self;
    }
  if (_bitsPerSample == 1)
    {
      const uint8_t *bits = [_pixels bytes];
      NSUInteger bpr = [self bytesPerRow], x, y;

      out = [NSMutableData dataWithLength: _width * _height];
      dst = [out mutableBytes];
      for (y = 0; y < _height; y++)
        {
          for (x = 0; x < _width; x++)
            {
              BOOL black = (bits[y * bpr + x / 8] >> (7 - x % 8)) & 1;

              dst[y * _width + x] = black ? 0 : 255;
            }
        }
      return [[SCImage alloc] initWithWidth: _width height: _height
                            samplesPerPixel: 1 bitsPerSample: 8
                                     pixels: out resolution: _resolution];
    }
  count = _width * _height * _samplesPerPixel;
  src = [_pixels bytes];
  out = [NSMutableData dataWithLength: count];
  dst = [out mutableBytes];
  for (i = 0; i < count; i++)
    {
      dst[i] = src[i] >> 8;
    }
  return [[SCImage alloc] initWithWidth: _width height: _height
                        samplesPerPixel: _samplesPerPixel bitsPerSample: 8
                                 pixels: out resolution: _resolution];
}

- (SCImage *) blackAndWhiteImageWithThreshold: (NSUInteger)threshold
{
  SCImage *eight;
  const uint8_t *src;
  NSMutableData *out;
  uint8_t *dst;
  NSUInteger bpr = (_width + 7) / 8, x, y;

  if (_bitsPerSample == 1)
    {
      return self;
    }
  eight = [self eightBitImage];
  src = [[eight pixels] bytes];
  out = [NSMutableData dataWithLength: bpr * _height];
  dst = [out mutableBytes];
  for (y = 0; y < _height; y++)
    {
      for (x = 0; x < _width; x++)
        {
          const uint8_t *p = src + (y * _width + x) * _samplesPerPixel;
          /* Rec. 601 luma: green looks brightest, blue darkest */
          NSUInteger luma = (_samplesPerPixel == 1) ? p[0]
            : (299 * p[0] + 587 * p[1] + 114 * p[2]) / 1000;

          if (luma < threshold)
            {
              dst[y * bpr + x / 8] |= 0x80 >> (x % 8);
            }
        }
    }
  return [[SCImage alloc] initWithWidth: _width height: _height
                        samplesPerPixel: 1 bitsPerSample: 1
                                 pixels: out resolution: _resolution];
}

@end
