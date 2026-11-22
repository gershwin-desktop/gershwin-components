/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_ImageAnalysis - finding the document on a preview, gamma tables. Headless. */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCImage.h"
#import "SCImageAnalysis.h"

static SCImage *
Page(NSUInteger w, NSUInteger h, NSRect doc, uint8_t lid, uint8_t paper)
{
  NSMutableData *d = [NSMutableData dataWithLength: w * h];
  uint8_t *p = [d mutableBytes];
  NSUInteger x, y;

  for (y = 0; y < h; y++)
    {
      for (x = 0; x < w; x++)
        {
          p[y * w + x] = NSPointInRect(NSMakePoint(x, y), doc) ? paper : lid;
        }
    }
  return [[[SCImage alloc] initWithWidth: w height: h samplesPerPixel: 1
                           bitsPerSample: 8 pixels: d resolution: 75]
           autorelease];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSRect r;
  SCImage *img;
  NSArray *t;

  r = SCContentRectOfImage(Page(200, 100, NSMakeRect(20, 10, 100, 50), 250, 30));
  PASS(NSEqualRects(r, NSMakeRect(0.1, 0.1, 0.5, 0.5)),
       "dark page on a white lid is found exactly");

  r = SCContentRectOfImage(Page(200, 100, NSMakeRect(0, 0, 150, 80), 20, 240));
  PASS(NSEqualRects(r, NSMakeRect(0, 0, 0.75, 0.8)),
       "light page touching the corner of a black lid is found");

  PASS(NSIsEmptyRect(SCContentRectOfImage(Page(200, 100, NSZeroRect, 250, 0))),
       "an empty bed finds nothing");

  img = Page(400, 400, NSMakeRect(100, 100, 50, 50), 250, 30);
  {
    uint8_t *p = (uint8_t *)[[img pixels] bytes];

    p[390 * 400 + 390] = 0;   /* a speck of dust */
  }
  r = SCContentRectOfImage(img);
  PASS(NSEqualRects(r, NSMakeRect(0.25, 0.25, 0.125, 0.125)),
       "a single dust speck does not stretch the box");

  t = SCGammaTable(256, 255, 0, 0, 1);
  PASS([[t objectAtIndex: 0] intValue] == 0 && [[t objectAtIndex: 128] intValue] == 128
       && [[t lastObject] intValue] == 255, "neutral settings give the identity");
  t = SCGammaTable(256, 255, 50, 0, 1);
  PASS([[t objectAtIndex: 0] intValue] == 128 && [[t lastObject] intValue] == 255,
       "brightness lifts and clamps");
  t = SCGammaTable(256, 255, 0, 0, 2.0);
  PASS([[t objectAtIndex: 64] intValue] > 64, "gamma above 1 brightens midtones");
  t = SCGammaTable(4, 4095, 0, 50, 1);
  PASS([t count] == 4 && [[t objectAtIndex: 0] intValue] == 0
       && [[t lastObject] intValue] == 4095, "contrast steepens, size and range follow the option");

  [arp release];
  return 0;
}
