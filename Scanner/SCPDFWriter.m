/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCPDFWriter.h"
#import "SCImage.h"
#import "SCImageBuilder.h"
#import "SCFax.h"
#include <zlib.h>

/* Width of every glyph of the invisible font, in thousandths of the font size */
static const int SCGlyphWidth = 500;

@implementation SCRecognizedWord

- (instancetype) initWithText: (NSString *)text box: (NSRect)box line: (NSUInteger)line
{
  self = [super init];
  if (self)
    {
      _text = [text copy];
      _box = box;
      _line = line;
    }
  return self;
}

@end

static NSError *
SCPDFError(NSString *path, NSString *reason)
{
  return [NSError errorWithDomain: SCScannerErrorDomain code: 5
                         userInfo: @{NSLocalizedDescriptionKey:
                                       [NSString stringWithFormat:
                                         @"Could not save \"%@\": %@",
                                         [path lastPathComponent], reason]}];
}

static NSData *
SCDeflate(NSData *data)
{
  uLongf size = compressBound([data length]);
  NSMutableData *out = [NSMutableData dataWithLength: size];

  if (compress2([out mutableBytes], &size, [data bytes], [data length],
                Z_BEST_COMPRESSION) != Z_OK)
    {
      return nil;
    }
  [out setLength: size];
  return out;
}

/* Collects numbered objects and writes them with their cross-reference table */
@interface SCPDFBuilder : NSObject
{
@public
  NSMutableData *_out;
  NSMutableArray *_offsets;
}
- (NSUInteger) reserve;
- (void) begin: (NSUInteger)number;
- (void) appendString: (NSString *)string;
- (void) object: (NSUInteger)number dictionary: (NSString *)dict;
- (void) object: (NSUInteger)number dictionary: (NSString *)dict stream: (NSData *)data;
- (NSData *) finishWithRoot: (NSUInteger)root;
@end

@implementation SCPDFBuilder

- (instancetype) init
{
  self = [super init];
  if (self)
    {
      _out = [NSMutableData data];
      _offsets = [NSMutableArray array];
      /* The binary comment tells tools the file is not plain text */
      [self appendString: @"%PDF-1.5\n%âãÏÓ\n"];
    }
  return self;
}

- (NSUInteger) reserve
{
  [_offsets addObject: @0];
  return [_offsets count];
}

- (void) appendString: (NSString *)string
{
  [_out appendData: [string dataUsingEncoding: NSISOLatin1StringEncoding]];
}

- (void) begin: (NSUInteger)number
{
  [_offsets replaceObjectAtIndex: number - 1
                      withObject: @([_out length])];
  [self appendString: [NSString stringWithFormat: @"%lu 0 obj\n",
                                (unsigned long)number]];
}

- (void) object: (NSUInteger)number dictionary: (NSString *)dict
{
  [self begin: number];
  [self appendString: [dict stringByAppendingString: @"\nendobj\n"]];
}

- (void) object: (NSUInteger)number dictionary: (NSString *)dict stream: (NSData *)data
{
  [self begin: number];
  [self appendString: [NSString stringWithFormat: @"<< %@ /Length %lu >>\nstream\n",
                                dict, (unsigned long)[data length]]];
  [_out appendData: data];
  [self appendString: @"\nendstream\nendobj\n"];
}

- (NSData *) finishWithRoot: (NSUInteger)root
{
  NSUInteger xref = [_out length];
  NSUInteger i;

  [self appendString: [NSString stringWithFormat: @"xref\n0 %lu\n0000000000 65535 f \n",
                                (unsigned long)[_offsets count] + 1]];
  for (i = 0; i < [_offsets count]; i++)
    {
      [self appendString: [NSString stringWithFormat: @"%010lu 00000 n \n",
                                    [[_offsets objectAtIndex: i] unsignedLongValue]]];
    }
  [self appendString: [NSString stringWithFormat:
    @"trailer\n<< /Size %lu /Root %lu 0 R >>\nstartxref\n%lu\n%%%%EOF\n",
    (unsigned long)[_offsets count] + 1, (unsigned long)root, (unsigned long)xref]];
  return _out;
}

@end

/* PDF numbers: no exponent, no locale, a few decimals */
static NSString *
SCNum(double v)
{
  return [NSString stringWithFormat: @"%.3f", v];
}

static NSString *
SCHexUTF16(NSString *text)
{
  NSMutableString *hex = [NSMutableString stringWithString: @"<"];
  NSUInteger i;

  for (i = 0; i < [text length]; i++)
    {
      [hex appendFormat: @"%04X", (unsigned)[text characterAtIndex: i]];
    }
  [hex appendString: @">"];
  return hex;
}

/*
 * Invisible text for one page (text render mode 3), word by word. Each word
 * but the last of a line carries a trailing space that reaches the next
 * word, so extracted text keeps its spaces; the horizontal scaling makes
 * every word exactly as wide as on the scan, so selections match it.
 */
static NSString *
SCTextLayer(NSArray *words, double scale, double pageHeight)
{
  NSMutableString *s = [NSMutableString stringWithString: @"BT\n3 Tr\n"];
  NSUInteger i;

  for (i = 0; i < [words count]; i++)
    {
      SCRecognizedWord *w = [words objectAtIndex: i];
      SCRecognizedWord *next = (i + 1 < [words count]) ? [words objectAtIndex: i + 1] : nil;
      BOOL lineGoesOn = (next != nil && [next line] == [w line]
                         && NSMinX([next box]) > NSMaxX([w box]));
      NSString *text = lineGoesOn ? [[w text] stringByAppendingString: @" "] : [w text];
      double width = (lineGoesOn ? NSMinX([next box]) - NSMinX([w box])
                                 : NSWidth([w box])) * scale;
      double size = NSHeight([w box]) * scale;
      double natural = [text length] * size * SCGlyphWidth / 1000.0;

      if ([text length] == 0 || size <= 0 || natural <= 0)
        {
          continue;
        }
      [s appendFormat: @"/T %@ Tf %@ Tz 1 0 0 1 %@ %@ Tm %@ Tj\n",
         SCNum(size), SCNum(100.0 * width / natural),
         SCNum(NSMinX([w box]) * scale),
         SCNum(pageHeight - NSMaxY([w box]) * scale), SCHexUTF16(text)];
    }
  [s appendString: @"ET\n"];
  return s;
}

/* The objects of the invisible font; returns the font's object number */
static NSUInteger
SCAddTextFont(SCPDFBuilder *pdf, NSData *fontFile)
{
  NSUInteger type0 = [pdf reserve], cidFont = [pdf reserve];
  NSUInteger descriptor = [pdf reserve], file = [pdf reserve];
  NSUInteger cidToGid = [pdf reserve], toUnicode = [pdf reserve];
  NSMutableData *map = [NSMutableData dataWithLength: 65536 * 2];
  uint8_t *m = [map mutableBytes];
  NSUInteger i;
  NSString *cmap =
    @"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
    @"/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
    @"/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
    @"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
    @"1 beginbfrange\n<0000> <FFFF> <0000>\nendbfrange\n"
    @"endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n";

  /* Every character code is shown with glyph 1, the font's only (empty) glyph */
  for (i = 0; i < 65536; i++)
    {
      m[2 * i] = 0;
      m[2 * i + 1] = 1;
    }
  [pdf object: type0 dictionary: [NSString stringWithFormat:
    @"<< /Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont "
    @"/Encoding /Identity-H /DescendantFonts [%lu 0 R] /ToUnicode %lu 0 R >>",
    (unsigned long)cidFont, (unsigned long)toUnicode]];
  [pdf object: cidFont dictionary: [NSString stringWithFormat:
    @"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont "
    @"/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
    @"/FontDescriptor %lu 0 R /DW %d /CIDToGIDMap %lu 0 R >>",
    (unsigned long)descriptor, SCGlyphWidth, (unsigned long)cidToGid]];
  [pdf object: descriptor dictionary: [NSString stringWithFormat:
    @"<< /Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 "
    @"/FontBBox [0 0 %d 1000] /ItalicAngle 0 /Ascent 1000 /Descent 0 "
    @"/CapHeight 1000 /StemV 80 /FontFile2 %lu 0 R >>",
    SCGlyphWidth, (unsigned long)file]];
  [pdf object: file dictionary: [NSString stringWithFormat:
    @"/Filter /FlateDecode /Length1 %lu", (unsigned long)[fontFile length]]
       stream: SCDeflate(fontFile)];
  [pdf object: cidToGid dictionary: @"/Filter /FlateDecode" stream: SCDeflate(map)];
  [pdf object: toUnicode dictionary: @"/Filter /FlateDecode"
       stream: SCDeflate([cmap dataUsingEncoding: NSASCIIStringEncoding])];
  return type0;
}

@implementation SCPDFWriter

+ (BOOL) writePDFWithImages: (NSArray *)images
                      words: (NSArray *)words
                   textFont: (NSString *)textFont
                     toFile: (NSString *)path
                      error: (NSError **)error
{
  SCPDFBuilder *pdf = [SCPDFBuilder new];
  NSUInteger catalog = [pdf reserve], pages = [pdf reserve];
  NSMutableArray *kids = [NSMutableArray array];
  NSUInteger font = 0, i;
  BOOL anyText = NO;

  if ([images count] == 0)
    {
      if (error)
        {
          *error = SCPDFError(path, @"there are no pages.");
        }
      return NO;
    }
  for (id w in words)
    {
      anyText = anyText || ([w isKindOfClass: [NSArray class]] && [w count] > 0);
    }
  if (anyText)
    {
      NSData *fontFile = [NSData dataWithContentsOfFile: textFont];

      if (fontFile == nil)
        {
          if (error)
            {
              *error = SCPDFError(path, [NSString stringWithFormat:
                @"the font for the text layer (%@) is missing.", textFont]);
            }
          return NO;
        }
      font = SCAddTextFont(pdf, fontFile);
    }

  for (i = 0; i < [images count]; i++)
    {
      SCImage *image = [images objectAtIndex: i];
      id pageWords = (i < [words count]) ? [words objectAtIndex: i] : nil;
      double dpi = [image resolution] > 0 ? [image resolution] : 72.0;
      double scale = 72.0 / dpi;
      double w = [image width] * scale, h = [image height] * scale;
      NSUInteger page = [pdf reserve], xobject = [pdf reserve], content = [pdf reserve];
      NSMutableString *ops;
      NSString *imageDict;
      NSData *imageData;

      if ([image bitsPerSample] == 1)
        {
          imageData = SCG4Data(image, error);
          if (imageData == nil)
            {
              return NO;
            }
          /* BlackIs1 false: decoded 0 bits are black, as DeviceGray shows them */
          imageDict = [NSString stringWithFormat:
            @"/Type /XObject /Subtype /Image /Width %lu /Height %lu "
            @"/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /CCITTFaxDecode "
            @"/DecodeParms << /K -1 /Columns %lu /Rows %lu /BlackIs1 false >>",
            (unsigned long)[image width], (unsigned long)[image height],
            (unsigned long)[image width], (unsigned long)[image height]];
        }
      else
        {
          SCImage *eight = [image eightBitImage];

          imageData = SCDeflate([eight pixels]);
          imageDict = [NSString stringWithFormat:
            @"/Type /XObject /Subtype /Image /Width %lu /Height %lu "
            @"/ColorSpace %@ /BitsPerComponent 8 /Filter /FlateDecode",
            (unsigned long)[image width], (unsigned long)[image height],
            [eight samplesPerPixel] == 3 ? @"/DeviceRGB" : @"/DeviceGray"];
        }
      if (imageData == nil)
        {
          if (error)
            {
              *error = SCPDFError(path, @"the image could not be compressed.");
            }
          return NO;
        }
      [pdf object: xobject dictionary: imageDict stream: imageData];

      ops = [NSMutableString stringWithFormat: @"q %@ 0 0 %@ 0 0 cm /Im0 Do Q\n",
                             SCNum(w), SCNum(h)];
      if ([pageWords isKindOfClass: [NSArray class]] && [pageWords count] > 0)
        {
          [ops appendString: SCTextLayer(pageWords, scale, h)];
        }
      [pdf object: content dictionary: @"/Filter /FlateDecode"
           stream: SCDeflate([ops dataUsingEncoding: NSASCIIStringEncoding])];

      [pdf object: page dictionary: [NSString stringWithFormat:
        @"<< /Type /Page /Parent %lu 0 R /MediaBox [0 0 %@ %@] "
        @"/Resources << /XObject << /Im0 %lu 0 R >>%@ >> /Contents %lu 0 R >>",
        (unsigned long)pages, SCNum(w), SCNum(h), (unsigned long)xobject,
        font ? [NSString stringWithFormat: @" /Font << /T %lu 0 R >>",
                         (unsigned long)font] : @"",
        (unsigned long)content]];
      [kids addObject: [NSString stringWithFormat: @"%lu 0 R", (unsigned long)page]];
    }

  [pdf object: pages dictionary: [NSString stringWithFormat:
    @"<< /Type /Pages /Kids [%@] /Count %lu >>",
    [kids componentsJoinedByString: @" "], (unsigned long)[kids count]]];
  [pdf object: catalog dictionary: [NSString stringWithFormat:
    @"<< /Type /Catalog /Pages %lu 0 R >>", (unsigned long)pages]];

  return [[pdf finishWithRoot: catalog] writeToFile: path
                                            options: NSDataWritingAtomic
                                              error: error];
}

@end
