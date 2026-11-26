/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCImageAnalysis.h"
#import "SCImage.h"
#include <math.h>
#include <stdlib.h>

/* Below this the difference is scanner noise or paper texture */
static const int SCContentThreshold = 40;

static int
SCCompareInts(const void *a, const void *b)
{
  return *(const int *)a - *(const int *)b;
}

NSRect
SCContentRectOfImage(SCImage *image)
{
  SCImage *eight = [image eightBitImage];
  NSUInteger w = [eight width], h = [eight height];
  NSUInteger spp = [eight samplesPerPixel];
  const uint8_t *px = [[eight pixels] bytes];
  NSUInteger x, y, n = 0, minX = w, minY = h, maxX = 0, maxY = 0;
  NSUInteger *rowHits, *colHits, minHits;
  int *border, background;

  if (w < 3 || h < 3)
    {
      return NSZeroRect;
    }

#define LUMA(xx, yy) (spp == 1 ? px[(yy) * w + (xx)] \
  : (px[((yy) * w + (xx)) * 3] + px[((yy) * w + (xx)) * 3 + 1] \
     + px[((yy) * w + (xx)) * 3 + 2]) / 3)

  /* The median of the edges is the lid, even when a page touches an edge */
  border = malloc(sizeof(int) * 2 * (w + h));
  for (x = 0; x < w; x++)
    {
      border[n++] = LUMA(x, 0);
      border[n++] = LUMA(x, h - 1);
    }
  for (y = 0; y < h; y++)
    {
      border[n++] = LUMA(0, y);
      border[n++] = LUMA(w - 1, y);
    }
  qsort(border, n, sizeof(int), SCCompareInts);
  background = border[n / 2];
  free(border);

  rowHits = calloc(h, sizeof(NSUInteger));
  colHits = calloc(w, sizeof(NSUInteger));
  for (y = 0; y < h; y++)
    {
      for (x = 0; x < w; x++)
        {
          if (abs((int)LUMA(x, y) - background) > SCContentThreshold)
            {
              rowHits[y]++;
              colHits[x]++;
            }
        }
    }
#undef LUMA

  /* Dust specks must not stretch the box, so a line needs a few hits */
  minHits = MAX(1, MIN(w, h) / 200);
  for (y = 0; y < h; y++)
    {
      if (rowHits[y] >= minHits)
        {
          minY = MIN(minY, y);
          maxY = MAX(maxY, y);
        }
    }
  for (x = 0; x < w; x++)
    {
      if (colHits[x] >= minHits)
        {
          minX = MIN(minX, x);
          maxX = MAX(maxX, x);
        }
    }
  free(rowHits);
  free(colHits);

  if (minX > maxX || minY > maxY)
    {
      return NSZeroRect;
    }
  return NSMakeRect((double)minX / w, (double)minY / h,
                    (double)(maxX + 1 - minX) / w,
                    (double)(maxY + 1 - minY) / h);
}

NSArray *
SCGammaTable(NSUInteger count, double maximum, double brightness,
             double contrast, double gamma)
{
  NSMutableArray *table = [NSMutableArray arrayWithCapacity: count];
  double slope = (100.0 + 2.0 * contrast) / 100.0;
  NSUInteger i;

  for (i = 0; i < count; i++)
    {
      double v = (count > 1) ? (double)i / (count - 1) : 0;

      v = pow(v, 1.0 / gamma);
      v = (v - 0.5) * slope + 0.5 + brightness / 100.0;
      v = MIN(1.0, MAX(0.0, v));
      [table addObject: [NSNumber numberWithInt: (int)lround(v * maximum)]];
    }
  return table;
}
