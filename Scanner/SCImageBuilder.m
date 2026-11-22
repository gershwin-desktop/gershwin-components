/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCImageBuilder.h"
#import "SCImage.h"
#include <string.h>

NSString * const SCScannerErrorDomain = @"io.github.gershwin-desktop.Scanner";

static NSError *
SCBuilderError(NSString *message)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 1
                         userInfo: @{NSLocalizedDescriptionKey: message}];
}

@interface SCFrame : NSObject
{
@public
  SANE_Parameters params;
  NSMutableData *data;
}
@end

@implementation SCFrame
@end

@implementation SCImageBuilder
{
  SCFrame *_single;      /* SANE_FRAME_GRAY or SANE_FRAME_RGB */
  SCFrame *_channels[3]; /* three-pass red, green, blue */
  SCFrame *_current;
  BOOL _complete;
}

- (BOOL) beginFrameWithParameters: (const SANE_Parameters *)params
                            error: (NSError **)error
{
  SCFrame *frame;

  if (params->depth != 1 && params->depth != 8 && params->depth != 16)
    {
      if (error)
        {
          *error = SCBuilderError([NSString stringWithFormat:
            @"The scanner delivers %d bits per sample, which is not supported.",
            params->depth]);
        }
      return NO;
    }
  if (params->bytes_per_line <= 0 || params->pixels_per_line <= 0)
    {
      if (error)
        {
          *error = SCBuilderError(@"The scanner reported an empty image.");
        }
      return NO;
    }

  frame = [SCFrame new];
  frame->params = *params;
  frame->data = [NSMutableData data];

  switch (params->format)
    {
      case SANE_FRAME_GRAY:
      case SANE_FRAME_RGB:
        _single = frame;
        break;
      case SANE_FRAME_RED:
        _channels[0] = frame;
        break;
      case SANE_FRAME_GREEN:
        _channels[1] = frame;
        break;
      case SANE_FRAME_BLUE:
        _channels[2] = frame;
        break;
      default:
        if (error)
          {
            *error = SCBuilderError(@"The scanner delivers an unknown frame format.");
          }
        return NO;
    }
  _current = frame;
  _complete = NO;
  return YES;
}

- (void) appendBytes: (const void *)bytes length: (NSUInteger)length
{
  NSAssert(_current != nil, @"appendBytes outside of a frame");
  [_current->data appendBytes: bytes length: length];
}

- (void) endFrame
{
  if (_current != nil && _current->params.last_frame)
    {
      _complete = YES;
    }
  _current = nil;
}

- (BOOL) isComplete
{
  return _complete;
}

- (double) frameProgress
{
  double total;

  if (_current == nil || _current->params.lines <= 0)
    {
      return 0.0;
    }
  total = (double)_current->params.bytes_per_line * _current->params.lines;
  return MIN(1.0, [_current->data length] / total);
}

static NSUInteger
SCFrameRows(SCFrame *f)
{
  NSUInteger rows = [f->data length] / f->params.bytes_per_line;

  if (f->params.lines > 0)
    {
      rows = MIN(rows, (NSUInteger)f->params.lines);
    }
  return rows;
}

/* Sample s of row r in a frame, scaled to the output depth */
static inline unsigned
SCSample(const uint8_t *row, NSUInteger s, int depth)
{
  if (depth == 1)
    {
      BOOL bit = (row[s / 8] >> (7 - (s % 8))) & 1;
      return bit ? 255 : 0;
    }
  if (depth == 8)
    {
      return row[s];
    }
  return ((const uint16_t *)row)[s];
}

- (SCImage *) imageWithResolution: (double)dpi error: (NSError **)error
{
  NSUInteger width, rows, spp, bps, r, x, c;
  NSMutableData *out;
  BOOL threePass = (_single == nil);
  SCFrame *ref;

  if (!_complete)
    {
      if (error)
        {
          *error = SCBuilderError(@"The scan ended before the image was complete.");
        }
      return nil;
    }

  if (threePass)
    {
      if (_channels[0] == nil || _channels[1] == nil || _channels[2] == nil)
        {
          if (error)
            {
              *error = SCBuilderError(@"The scanner did not deliver all three color passes.");
            }
          return nil;
        }
      ref = _channels[0];
      rows = MIN(SCFrameRows(_channels[0]),
                 MIN(SCFrameRows(_channels[1]), SCFrameRows(_channels[2])));
      spp = 3;
    }
  else
    {
      ref = _single;
      rows = SCFrameRows(_single);
      spp = (_single->params.format == SANE_FRAME_RGB) ? 3 : 1;
    }

  width = ref->params.pixels_per_line;
  bps = (ref->params.depth == 16) ? 16 : 8;
  if (rows == 0)
    {
      if (error)
        {
          *error = SCBuilderError(@"The scanner delivered no image data.");
        }
      return nil;
    }

  /* Line art stays 1-bit, so it can be saved small and fax-compressed */
  if (!threePass && spp == 1 && ref->params.depth == 1)
    {
      NSUInteger bpr = (width + 7) / 8;
      const uint8_t *in = [_single->data bytes];

      out = [NSMutableData dataWithLength: bpr * rows];
      for (r = 0; r < rows; r++)
        {
          memcpy((uint8_t *)[out mutableBytes] + r * bpr,
                 in + r * ref->params.bytes_per_line, bpr);
        }
      return [[SCImage alloc] initWithWidth: width height: rows
                            samplesPerPixel: 1 bitsPerSample: 1
                                     pixels: out resolution: dpi];
    }

  out = [NSMutableData dataWithLength: width * rows * spp * (bps / 8)];
  uint8_t *out8 = [out mutableBytes];
  uint16_t *out16 = (uint16_t *)out8;
  const uint8_t *src[3];

  if (threePass)
    {
      for (c = 0; c < 3; c++)
        {
          src[c] = [_channels[c]->data bytes];
        }
    }
  else
    {
      src[0] = [_single->data bytes];
    }

  for (r = 0; r < rows; r++)
    {
      for (x = 0; x < width; x++)
        {
          for (c = 0; c < spp; c++)
            {
              unsigned v;
              NSUInteger o = (r * width + x) * spp + c;

              if (threePass)
                {
                  SCFrame *f = _channels[c];
                  const uint8_t *row = src[c] + r * f->params.bytes_per_line;
                  v = SCSample(row, x, f->params.depth);
                }
              else
                {
                  const uint8_t *row = src[0] + r * _single->params.bytes_per_line;
                  /* RGB bits are intensities; gray line art returned above */
                  v = SCSample(row, x * spp + c, _single->params.depth);
                }

              if (bps == 16)
                {
                  out16[o] = v;
                }
              else
                {
                  out8[o] = v;
                }
            }
        }
    }

  return [[SCImage alloc] initWithWidth: width height: rows
                        samplesPerPixel: spp bitsPerSample: bps
                                 pixels: out resolution: dpi];
}

@end
