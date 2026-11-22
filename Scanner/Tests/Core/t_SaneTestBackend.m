/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * t_SaneTestBackend - SCScanner against the SANE "test" backend, which ships
 * with sane-backends and simulates a scanner, so options, area, scanning and
 * the document feeder are exercised for real without hardware. Headless.
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "SCScanner.h"
#import "SCOption.h"
#import "SCImage.h"
#include <stdlib.h>

@interface Collector : NSObject <SCScannerDelegate>
{
@public
  NSMutableArray *images;
  BOOL finished;
  BOOL cancelled;
  NSError *error;
}
@end

@implementation Collector
- (id) init
{
  self = [super init];
  images = [NSMutableArray new];
  return self;
}
- (void) scanner: (SCScanner *)s didScanImage: (SCImage *)image
{
  [images addObject: image];
}
- (void) scanner: (SCScanner *)s progress: (double)f
{
}
- (void) scannerDidFinish: (SCScanner *)s cancelled: (BOOL)c error: (NSError *)e
{
  finished = YES;
  cancelled = c;
  error = [e retain];
}
@end

static Collector *
Scan(SCScanner *scanner, BOOL multi)
{
  Collector *c = [[Collector new] autorelease];
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 30];

  [scanner setDelegate: c];
  [scanner startScanAllowingMultiplePages: multi];
  while (!c->finished && [limit timeIntervalSinceNow] > 0)
    {
      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                               beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
    }
  return c;
}

static BOOL
Set(SCScanner *s, NSString *name, id value)
{
  return [s setValue: value forOption: [s optionNamed: name] error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *conf = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_SaneTestBackend-%d", getpid()]];
  NSFileManager *fm = [NSFileManager defaultManager];
  SCDeviceInfo *device = nil;
  SCScanner *scanner;
  NSError *error = nil;
  NSArray *devices;
  Collector *c;

  /* Only the simulated scanner, so the test never touches real devices */
  [fm createDirectoryAtPath: conf withIntermediateDirectories: YES
                 attributes: nil error: NULL];
  [@"test\n" writeToFile: [conf stringByAppendingPathComponent: @"dll.conf"]
              atomically: NO encoding: NSUTF8StringEncoding error: NULL];
  setenv("SANE_CONFIG_DIR", [conf fileSystemRepresentation], 1);

  PASS([SCScanner initializeSANEWithError: &error], "SANE initializes");
  devices = [SCScanner devicesWithError: &error];
  for (SCDeviceInfo *d in devices)
    {
      if ([[d name] isEqualToString: @"test:0"])
        {
          device = d;
        }
    }
  NEED(PASS(device != nil, "test backend lists test:0"));
  PASS_EQUAL([device displayName], @"frontend-tester",
             "a Noname vendor is left out of the display name");

  START_SET("airscan names")
    {
      NSArray *alt = SCAirscanAlternativeNames(@"airscan:w1:Samsung C48x Series (SEC8425197051DB)");

      PASS_EQUAL([alt objectAtIndex: 0], @"airscan:w0:Samsung C48x Series (SEC8425197051DB)",
                 "the other numbers of the same protocol come first");
      PASS(![alt containsObject: @"airscan:w1:Samsung C48x Series (SEC8425197051DB)"]
           && [alt containsObject: @"airscan:e0:Samsung C48x Series (SEC8425197051DB)"]
           && [alt count] == 19, "then the other protocol, never the name itself");
      PASS_EQUAL(SCAirscanAlternativeNames(@"airscan:e0:HP: Office Jet")
                   [9], @"airscan:w0:HP: Office Jet", "colons in the name are kept");
      PASS([SCAirscanAlternativeNames(@"pixma:04A9176D_1234") count] == 0,
           "names of other drivers have no alternatives");
    }
  END_SET("airscan names")

  {
    /* A device that is not there fails with the error of the name asked for */
    SCDeviceInfo *gone = [[[SCDeviceInfo alloc] initWithName: @"test:7" vendor: @""
                                                       model: @"gone" kind: @""] autorelease];
    PASS([SCScanner scannerOpeningDevice: gone error: &error] == nil && error != nil,
         "opening a missing device still fails");
  }

  scanner = [[[SCScanner alloc] initWithDevice: device error: &error] autorelease];
  NEED(PASS(scanner != nil, "device opens"));

  START_SET("options")
    {
      SCOption *mode = [scanner optionNamed: @"mode"];
      SCOption *res = [scanner optionNamed: @"resolution"];
      SCOption *gamma = [scanner optionNamed: @"gamma-table"];

      PASS([mode type] == SCOptionTypeString
           && [[mode listValues] containsObject: @"Color"],
           "mode is a string list");
      PASS([res type] == SCOptionTypeFixed && [res unit] == SANE_UNIT_DPI
           && [[res value] doubleValue] > 0, "resolution is fixed-point dpi");
      PASS([[res groupTitle] length] > 0, "options carry their group title");
      PASS([gamma count] > 1 && [[gamma value] count] == [gamma count]
           && [gamma isAdvanced], "gamma table is an advanced array option");
      PASS(![[scanner optionNamed: @"three-pass"] isActive],
           "three-pass is inactive in gray mode");
      PASS(Set(scanner, @"mode", @"Color"), "mode can be set");
      PASS([[scanner optionNamed: @"three-pass"] isActive],
           "options reload after the driver asks for it");
      PASS(!Set(scanner, @"mode", @42), "a number is refused for a string option");
      Set(scanner, @"mode", @"Gray");
    }
  END_SET("options")

  START_SET("scan area")
    {
      NSRect area;

      PASS([scanner hasScanArea], "test backend has a scan area");
      PASS(NSEqualSizes([scanner scanAreaSizeInMillimeters], NSMakeSize(200, 200)),
           "full area is 200 x 200 mm");
      PASS([scanner setNormalizedScanArea: NSMakeRect(0.25, 0.5, 0.5, 0.25)
                                    error: &error], "area can be set");
      PASS([[[scanner optionNamed: @"tl-x"] value] doubleValue] == 50
           && [[[scanner optionNamed: @"br-y"] value] doubleValue] == 150,
           "fractions map onto the option range");
      area = [scanner normalizedScanArea];
      PASS(NSEqualRects(area, NSMakeRect(0.25, 0.5, 0.5, 0.25)),
           "area reads back as fractions");
      PASS([scanner setNormalizedScanArea: NSMakeRect(0.8, 0.8, 0.1, 0.1)
                                    error: NULL]
           && [scanner setNormalizedScanArea: NSMakeRect(0, 0, 0.1, 0.1)
                                       error: NULL]
           && NSEqualRects([scanner normalizedScanArea], NSMakeRect(0, 0, 0.1, 0.1)),
           "moving the area across its old corners works in both directions");
    }
  END_SET("scan area")

  START_SET("scanning")
    {
      const uint8_t *px;
      SCImage *img;
      NSDictionary *saved;

      /* 0.1 x 0.1 of 200 mm at 50 dpi is 20 mm, about 39 pixels */
      Set(scanner, @"resolution", @50.0);
      Set(scanner, @"test-picture", @"Solid white");
      c = Scan(scanner, NO);
      PASS(c->finished && c->error == nil && [c->images count] == 1,
           "gray scan delivers one page");
      img = [c->images lastObject];
      PASS([img width] >= 38 && [img width] <= 40 && [img height] >= 38
           && [img height] <= 40, "size follows area and resolution");
      PASS([img resolution] == 50, "image carries the scan resolution");
      px = [[img pixels] bytes];
      PASS(px[0] == 255, "solid white scans white");

      Set(scanner, @"depth", @1);
      Set(scanner, @"test-picture", @"Solid black");
      c = Scan(scanner, NO);
      img = [c->images lastObject];
      PASS([img bitsPerSample] == 1 && ((const uint8_t *)[[img pixels] bytes])[0] == 0xff,
           "line art solid black scans as 1-bit black");

      Set(scanner, @"depth", @16);
      Set(scanner, @"mode", @"Color");
      Set(scanner, @"three-pass", @YES);
      Set(scanner, @"test-picture", @"Solid white");
      c = Scan(scanner, NO);
      img = [c->images lastObject];
      PASS(c->error == nil && [img samplesPerPixel] == 3 && [img bitsPerSample] == 16
           && ((const uint16_t *)[[img pixels] bytes])[2] == 0xffff,
           "16-bit three-pass color scan");

      saved = [scanner savedValues];
      Set(scanner, @"three-pass", @NO);
      Set(scanner, @"mode", @"Gray");
      [scanner restoreValues: saved];
      PASS([[[scanner optionNamed: @"three-pass"] value] boolValue],
           "restoring brings back a value that depends on another one");
      Set(scanner, @"three-pass", @NO);
      Set(scanner, @"mode", @"Gray");
      Set(scanner, @"depth", @8);

      PASS(![scanner sourceFeedsMultiplePages], "flatbed is a single page");
      Set(scanner, @"source", @"Automatic Document Feeder");
      PASS([scanner sourceFeedsMultiplePages], "document feeder is recognized");
      c = Scan(scanner, YES);
      PASS(c->error == nil && !c->cancelled && [c->images count] > 1,
           "feeder scan continues until the feeder is empty");
      Set(scanner, @"source", @"Flatbed");

      /*
       * A full-area 1200 dpi page outlasts the cancel. The read delay keeps
       * the backend's reader thread sleeping: SANE cancels that thread
       * asynchronously, and one cancelled inside malloc deadlocks
       * sane_cancel itself (the same happens with real drivers that use
       * sanei_thread, but rarely, since their reader mostly waits for I/O).
       */
      [scanner setNormalizedScanArea: NSMakeRect(0, 0, 1, 1) error: NULL];
      Set(scanner, @"resolution", @1200.0);
      Set(scanner, @"read-delay", @YES);
      Set(scanner, @"read-delay-duration", @200000);
      {
        Collector *cc = [[Collector new] autorelease];
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow: 30];

        [scanner setDelegate: cc];
        [scanner startScanAllowingMultiplePages: NO];
        [NSThread sleepForTimeInterval: 0.05];
        [scanner cancel];
        while (!cc->finished && [limit timeIntervalSinceNow] > 0)
          {
            [[NSRunLoop currentRunLoop]
              runMode: NSDefaultRunLoopMode
              beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
          }
        PASS(cc->finished && cc->cancelled && cc->error == nil
             && [cc->images count] == 0, "cancel ends a slow scan without an error");
      }
    }
  END_SET("scanning")

  [scanner close];
  [SCScanner exitSANE];
  [fm removeItemAtPath: conf error: NULL];
  PASS([SCScanner mustSkipExitHandlers], "a cancelled scan is remembered");
  [arp release];
  /* Same reason as in the app: exit handlers can deadlock after a cancel */
  fflush(stderr);
  _exit(0);
}
