/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * t_WSD - scanning from a printer's panel: what the printer says (answers
 * recorded from a Samsung C48x, anonymized, in Fixtures/), what Scanner
 * sends, MTOM image parts, TIFF pages, and the event receiver. Headless.
 */

#import <AppKit/AppKit.h>
#import "Testing.h"
#import "SCWSDClient.h"
#import "SCWSDEventListener.h"
#import "SCImage.h"
#import "SCImageWriter.h"
#import "SCFax.h"
#import "SCHTTPPost.h"
#include <tiffio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>

static NSString *
Fixture(NSString *name)
{
  return [NSString stringWithContentsOfFile: [@"Fixtures" stringByAppendingPathComponent: name]
                                   encoding: NSUTF8StringEncoding error: NULL];
}

static SCImage *
Gradient(NSUInteger spp, NSUInteger bps)
{
  NSUInteger w = 37, h = 11, bpr = (bps == 1) ? (w + 7) / 8 : w * spp;
  NSMutableData *d = [NSMutableData dataWithLength: bpr * h];
  uint8_t *p = [d mutableBytes];
  NSUInteger i;

  for (i = 0; i < [d length]; i++)
    {
      p[i] = (uint8_t)(i * 13);
    }
  /* Bits past the right edge of a 1-bit row carry nothing and are not stored */
  if (bps == 1)
    {
      for (i = 0; i < h; i++)
        {
          p[i * bpr + bpr - 1] &= (uint8_t)(0xff << (8 - w % 8));
        }
    }
  return [[[SCImage alloc] initWithWidth: w height: h samplesPerPixel: spp
                           bitsPerSample: bps pixels: d resolution: 200] autorelease];
}

static NSData *
Bytes(const char *s)
{
  return [NSData dataWithBytes: s length: strlen(s)];
}

/* A page as printers send it: TIFF with JPEG strips (compression 7) */
static NSData *
JPEGTIFF(NSString *path, uint16_t spp, uint16_t photometric, uint32_t w, uint32_t h)
{
  TIFF *tif = TIFFOpen([path fileSystemRepresentation], "w");
  NSMutableData *row = [NSMutableData dataWithLength: w * spp];
  uint32_t x, y;

  TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, w);
  TIFFSetField(tif, TIFFTAG_IMAGELENGTH, h);
  TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 8);
  TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, spp);
  TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_JPEG);
  TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, photometric);
  TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, h);
  TIFFSetField(tif, TIFFTAG_JPEGQUALITY, 95);
  if (photometric == PHOTOMETRIC_YCBCR)
    {
      TIFFSetField(tif, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB);
    }
  for (y = 0; y < h; y++)
    {
      uint8_t *p = [row mutableBytes];

      for (x = 0; x < w * spp; x++)
        {
          p[x] = (uint8_t)(64 + (x / spp + y) % 128);
        }
      TIFFWriteScanline(tif, p, y, 0);
    }
  TIFFClose(tif);
  return [NSData dataWithContentsOfFile: path];
}

/* Mean difference to what JPEGTIFF wrote; JPEG is lossy, so only close is right */
static double
Distance(SCImage *img)
{
  const uint8_t *p = [[img pixels] bytes];
  NSUInteger spp = [img samplesPerPixel], w = [img width], x, y;
  double sum = 0;

  for (y = 0; y < [img height]; y++)
    {
      for (x = 0; x < w * spp; x++)
        {
          sum += fabs((double)p[y * w * spp + x] - (64 + (x / spp + y) % 128));
        }
    }
  return sum / (double)[[img pixels] length];
}

/* Answers one request with canned bytes, as a printer would */
static int serverSocket = -1;
static NSData *serverAnswer;

static void *
Serve(void *unused)
{
  int c = accept(serverSocket, NULL, NULL);
  char buf[4096];
  NSUInteger sent = 0;

  /* The request is small; one read takes it, and its content does not matter */
  read(c, buf, sizeof(buf));
  while (sent < [serverAnswer length])
    {
      /* Small writes, so the client sees the answer in many pieces */
      ssize_t n = write(c, (const char *)[serverAnswer bytes] + sent,
                        MIN((NSUInteger)1000, [serverAnswer length] - sent));

      if (n <= 0)
        {
          break;
        }
      sent += n;
    }
  close(c);
  return NULL;
}

static NSURL *
StartServer(NSData *answer)
{
  struct sockaddr_in a;
  socklen_t len = sizeof(a);
  pthread_t t;

  serverAnswer = [answer retain];
  serverSocket = socket(AF_INET, SOCK_STREAM, 0);
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  bind(serverSocket, (struct sockaddr *)&a, sizeof(a));
  listen(serverSocket, 1);
  getsockname(serverSocket, (struct sockaddr *)&a, &len);
  pthread_create(&t, NULL, Serve, NULL);
  pthread_detach(t);
  return [NSURL URLWithString: [NSString stringWithFormat: @"http://127.0.0.1:%d/wsd/scan",
                                         ntohs(a.sin_port)]];
}

static BOOL received;
static NSString *receivedIdentifier;

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"t_WSD-%d", getpid()]];
  NSFileManager *fm = [NSFileManager defaultManager];

  START_SET("the printer's answers")
    {
      SCWSDSubscription *s = [SCWSDClient subscriptionFromResponse:
                                Fixture(@"subscribe-response.xml")];
      SCWSDScanEvent *e = [SCWSDClient scanEventFromXML: Fixture(@"scan-event.xml")];

      PASS_EQUAL([SCWSDClient scanServiceAddressInMetadata: Fixture(@"metadata.xml")],
                 @"http://192.0.2.30:8018/wsd/scan",
                 "the scan service is found among the hosted services");
      PASS_EQUAL([s managerAddress], @"http://192.0.2.30:8018/wsd/scan",
                 "subscription manager");
      PASS([[s identifier] hasPrefix: @"uuid:"], "subscription identifier");
      PASS([[s destinationToken] hasPrefix: @"Client_"], "destination token");
      PASS_EQUAL([e inputSource], @"Platen", "the event names the input source");
      PASS_EQUAL([e clientContext], @"GershwinTest", "and whose destination was picked");
      PASS([[e scanIdentifier] length] == 36, "and the scan to answer");
      PASS([SCWSDClient scanEventFromXML: Fixture(@"metadata.xml")] == nil,
           "other messages are no scan events");
      {
        uint8_t binary[] = {'-', '-', 'M', 0xff, 0xfe, 'F', 'a', 'u', 'l', 't', 0x80};
        NSData *fault = [@"<soap:Envelope><soap:Body><soap:Fault/></soap:Body></soap:Envelope>"
                          dataUsingEncoding: NSUTF8StringEncoding];

        PASS([SCWSDClient faultInResponse:
                [NSData dataWithBytes: binary length: sizeof(binary)]] == nil,
             "an image answer (binary, no valid text) is never taken for a fault");
        PASS([SCWSDClient faultInResponse: fault] != nil, "a SOAP fault is recognized");
      }
      PASS_EQUAL([SCWSDClient valueOfElement: @"Value" inXML:
                    @"<SOAP-ENV:Subcode><SOAP-ENV:Value>wscn:ServerErrorNotAcceptingJobs"
                    @"</SOAP-ENV:Value></SOAP-ENV:Subcode>"],
                 @"wscn:ServerErrorNotAcceptingJobs",
                 "prefixes with a hyphen, as some printers write them, are read too");
    }
  END_SET("the printer's answers")

  START_SET("the scan job request")
    {
      SCWSDScanEvent *e = [SCWSDClient scanEventFromXML: Fixture(@"scan-event.xml")];
      SCWSDScanTicket *t = [[SCWSDScanTicket new] autorelease];
      NSString *body;

      [t setInputSource: @"Platen"];
      [t setColorProcessing: @"RGB24"];
      [t setResolution: 300];
      [t setRegion: NSMakeRect(0, 0, 8268, 11693)];
      body = [SCWSDClient createScanJobBodyForEvent: e destinationToken: @"Client_1"
                                             ticket: t to: @"http://192.0.2.30:8018/wsd/scan"];
      PASS([SCWSDClient valueOfElement: @"ScanIdentifier" inXML: body] != nil
           && [[SCWSDClient valueOfElement: @"ScanIdentifier" inXML: body]
                isEqualToString: [e scanIdentifier]], "answers the panel's scan");
      PASS_EQUAL([SCWSDClient valueOfElement: @"DestinationToken" inXML: body], @"Client_1",
                 "with this computer's destination token");
      PASS_EQUAL([SCWSDClient valueOfElement: @"ImagesToTransfer" inXML: body], @"1",
                 "the flatbed holds one page");
      PASS_EQUAL([SCWSDClient valueOfElement: @"ScanRegionHeight" inXML: body], @"11693",
                 "the area in thousandths of an inch");
      PASS_EQUAL([SCWSDClient valueOfElement: @"Format" inXML: body],
                 @"tiff-single-uncompressed", "lossless pages");
      [t setInputSource: @"ADF"];
      body = [SCWSDClient createScanJobBodyForEvent: e destinationToken: @"Client_1"
                                             ticket: t to: @"x"];
      PASS_EQUAL([SCWSDClient valueOfElement: @"ImagesToTransfer" inXML: body], @"0",
                 "the feeder delivers every sheet");
    }
  END_SET("the scan job request")

  START_SET("MTOM")
    {
      uint8_t image[] = {0x49, 0x49, 0x2a, 0x00, '\r', '\n', '-', '-', 0x00, 0xff};
      NSMutableData *body = [NSMutableData data];
      NSData *got;

      [body appendData: [@"--MIMEBoundary_x\r\nContent-Type: application/xop+xml; "
                         @"type=\"application/soap+xml\"\r\n\r\n<soap:Envelope/>\r\n"
                         @"--MIMEBoundary_x\r\nContent-Type: application/octet-stream\r\n"
                         @"Content-ID: <image>\r\n\r\n" dataUsingEncoding: NSASCIIStringEncoding]];
      [body appendBytes: image length: sizeof(image)];
      [body appendData: [@"\r\n--MIMEBoundary_x--\r\n" dataUsingEncoding: NSASCIIStringEncoding]];
      got = [SCWSDClient imageFromMTOMBody: body contentType:
               @"multipart/related; type=\"application/xop+xml\"; "
               @"boundary=\"MIMEBoundary_x\"; start=\"<root>\""];
      PASS([got isEqualToData: [NSData dataWithBytes: image length: sizeof(image)]],
           "the image part comes out byte for byte, line breaks inside it included");
    }
  END_SET("MTOM")

  START_SET("HTTP framing")
    {
      NSUInteger used = 0;
      BOOL bad = YES;
      NSData *d;
      SCHTTPResponse *r;

      d = [SCHTTPPost dataByDecodingChunks: Bytes("4;name=x\r\nWiki\r\n5\r\npedia\r\n"
                                                  "0\r\nExpires: never\r\n\r\nrest")
                                  consumed: &used malformed: &bad];
      PASS([d isEqualToData: Bytes("Wikipedia")] && !bad && used == 47,
           "chunks join up, with extensions and trailers skipped");
      d = [SCHTTPPost dataByDecodingChunks: Bytes("A\nabcdefghij\n0\n\n")
                                  consumed: &used malformed: &bad];
      PASS([d isEqualToData: Bytes("abcdefghij")], "bare line feeds end lines too");
      d = [SCHTTPPost dataByDecodingChunks: Bytes("c00\r\nshort")
                                  consumed: &used malformed: &bad];
      PASS(d == nil && !bad, "a body still arriving is incomplete, not broken");
      d = [SCHTTPPost dataByDecodingChunks: Bytes("zz\r\nab\r\n0\r\n\r\n")
                                  consumed: &used malformed: &bad];
      PASS(d == nil && bad, "a size that is not hexadecimal is broken");
      d = [SCHTTPPost dataByDecodingChunks: Bytes("2\r\nabc\r\n0\r\n\r\n")
                                  consumed: &used malformed: &bad];
      PASS(d == nil && bad, "a chunk longer than its size is broken");

      r = [SCHTTPResponse responseFromData:
             Bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: a/b\r\n\r\nhello!")
                               endOfStream: NO malformed: &bad];
      PASS([r statusCode] == 200 && [[r body] isEqualToData: Bytes("hello")]
           && [[r headers][@"content-type"] isEqualToString: @"a/b"],
           "Content-Length bounds the body");
      r = [SCHTTPResponse responseFromData: Bytes("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nhello")
                               endOfStream: NO malformed: &bad];
      PASS(r == nil && !bad, "a shorter body is waited for");
      r = [SCHTTPResponse responseFromData: Bytes("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nhello")
                               endOfStream: YES malformed: &bad];
      PASS(r == nil && bad, "and broken when the connection closes before it is complete");
      r = [SCHTTPResponse responseFromData:
             Bytes("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 202 Accepted\r\n"
                   "Transfer-Encoding: chunked\r\nContent-Length: 99\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
                               endOfStream: NO malformed: &bad];
      PASS([r statusCode] == 202 && [[r body] isEqualToData: Bytes("abc")],
           "interim answers are skipped and chunking wins over Content-Length");
      r = [SCHTTPResponse responseFromData: Bytes("HTTP/1.0 200 OK\r\n\r\nuntil the end")
                               endOfStream: YES malformed: &bad];
      PASS([[r body] isEqualToData: Bytes("until the end")],
           "without a length the body lasts until the connection closes");
      r = [SCHTTPResponse responseFromData: Bytes("SSH-2.0-OpenSSH\r\n\r\n")
                               endOfStream: NO malformed: &bad];
      PASS(r == nil && bad, "something that is not HTTP is refused");
    }
  END_SET("HTTP framing")

  START_SET("a page sent in chunks")
    {
      /* MTOM in chunks of 0xc00, as a Samsung C48x sends pages */
      NSMutableData *page = [NSMutableData dataWithLength: 20000];
      NSMutableData *body = [NSMutableData data], *wire = [NSMutableData data];
      NSString *type = @"multipart/related; boundary=_DPWS_v1; type=\"application/xop+xml\"";
      NSUInteger i;
      NSError *error = nil;
      SCHTTPResponse *r;

      for (i = 0; i < [page length]; i++)
        {
          ((uint8_t *)[page mutableBytes])[i] = (uint8_t)(i * 7 + i / 251);
        }
      [body appendData: Bytes("--_DPWS_v1\r\nContent-Type: application/xop+xml\r\n\r\n"
                              "<s:Envelope/>\r\n--_DPWS_v1\r\nContent-Type: image/tiff\r\n"
                              "Content-ID: <image>\r\n\r\n")];
      [body appendData: page];
      [body appendData: Bytes("\r\n--_DPWS_v1--\r\n")];
      [wire appendData: [[NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nTransfer-Encoding: chunked\r\n\r\n", type]
                          dataUsingEncoding: NSASCIIStringEncoding]];
      for (i = 0; i < [body length]; i += 0xc00)
        {
          NSUInteger n = MIN((NSUInteger)0xc00, [body length] - i);

          [wire appendData: [[NSString stringWithFormat: @"%lx\r\n", (unsigned long)n]
                              dataUsingEncoding: NSASCIIStringEncoding]];
          [wire appendData: [body subdataWithRange: NSMakeRange(i, n)]];
          [wire appendData: Bytes("\r\n")];
        }
      [wire appendData: Bytes("0\r\n\r\n")];

      r = [SCHTTPPost post: Bytes("<s:Envelope/>") contentType: @"application/soap+xml"
                        to: StartServer(wire) timeout: 5 error: &error];
      PASS([r statusCode] == 200 && [[r body] isEqualToData: body],
           "the body arrives without its chunk framing");
      PASS([[SCWSDClient imageFromMTOMBody: [r body] contentType: [r headers][@"content-type"]]
             isEqualToData: page], "and the page comes out byte for byte");
      r = [SCHTTPPost post: [NSData data] contentType: @"a/b"
                        to: [NSURL URLWithString: @"https://127.0.0.1/"] timeout: 1 error: &error];
      PASS(r == nil && error != nil, "only http addresses are taken");
    }
  END_SET("a page sent in chunks")

  START_SET("TIFF pages")
    {
      NSString *path = [dir stringByAppendingPathComponent: @"page.tiff"];
      NSUInteger spp, k;
      NSError *error = nil;

      [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                     attributes: nil error: NULL];
      for (k = 0; k < 3; k++)
        {
          SCImage *in = (k == 0) ? Gradient(1, 8) : (k == 1) ? Gradient(3, 8) : Gradient(1, 1);
          SCImage *out;

          spp = [in samplesPerPixel];
          [SCImageWriter writeImage: in toFile: path format: SCFileFormatTIFF
                            quality: 0 error: &error];
          out = SCImageFromTIFFData([NSData dataWithContentsOfFile: path], &error);
          PASS([out width] == [in width] && [out height] == [in height]
               && [out samplesPerPixel] == spp
               && [out bitsPerSample] == [in bitsPerSample]
               && [[out pixels] isEqualToData: [in pixels]],
               "a %s page reads back pixel for pixel",
               k == 0 ? "gray" : k == 1 ? "color" : "black and white");
          PASS((NSUInteger)([out resolution] + 0.5) == 200, "with its resolution");
        }
      {
        SCImage *gray = SCImageFromTIFFData(JPEGTIFF(path, 1, PHOTOMETRIC_MINISBLACK, 64, 48),
                                            &error);
        SCImage *color = SCImageFromTIFFData(JPEGTIFF(path, 3, PHOTOMETRIC_YCBCR, 64, 48),
                                             &error);

        PASS([gray width] == 64 && [gray height] == 48 && [gray samplesPerPixel] == 1
             && Distance(gray) < 3, "a gray JPEG-compressed page reads");
        PASS([color width] == 64 && [color samplesPerPixel] == 3 && [color bitsPerSample] == 8
             && Distance(color) < 3, "a color JPEG-compressed page reads as RGB");
      }
      PASS(SCImageFromTIFFData([@"no tiff" dataUsingEncoding: NSASCIIStringEncoding],
                               &error) == nil && error != nil,
           "something else is refused with a message");
      [fm removeItemAtPath: dir error: NULL];
    }
  END_SET("TIFF pages")

  START_SET("event receiver")
    {
      SCWSDEventListener *l = [[[SCWSDEventListener alloc]
                                 initWithPrinterHost: @"127.0.0.1"
                                             handler: ^(SCWSDScanEvent *event) {
          received = YES;
          receivedIdentifier = [[event scanIdentifier] copy];
        }] autorelease];
      NSMutableURLRequest *post;
      NSDate *limit;

      PASS([l start], "the receiver opens a port");
      PASS([[l notifyURL] hasPrefix: @"http://127.0.0.1:"],
           "and names the address the printer reaches it at");
      post = [NSMutableURLRequest requestWithURL: [NSURL URLWithString: [l notifyURL]]];
      [post setHTTPMethod: @"POST"];
      [post setHTTPBody: [Fixture(@"scan-event.xml") dataUsingEncoding: NSUTF8StringEncoding]];
      [NSURLConnection sendSynchronousRequest: post returningResponse: NULL error: NULL];
      limit = [NSDate dateWithTimeIntervalSinceNow: 5];
      while (!received && [limit timeIntervalSinceNow] > 0)
        {
          [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                   beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
        }
      PASS(received && [receivedIdentifier length] == 36,
           "the printer's notification reaches the handler on the main thread");
      [l stop];
    }
  END_SET("event receiver")

  [arp release];
  return 0;
}
