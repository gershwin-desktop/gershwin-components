/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "IconConverter.h"
#import <AppKit/NSBitmapImageRep.h>

@implementation IconConverter

// A copy the PNG encoder can write as it is: 8 bits per sample, colour
// samples before alpha, and alpha not premultiplied. PNG stores RGB only in
// 8 or 16 bits, so old 4-bit TIFF icons have to be widened; 16-bit ones are
// narrowed because libs-gui's PNG writer hands 16-bit samples to libpng in
// host byte order, which swaps the bytes of every sample on little-endian
// machines - and an icon gains nothing visible from 16 bits anyway.
// The un-premultiplying is done here rather than left to the encoder because
// libs-gui's PNG writer passes premultiplied samples through unchanged, which
// darkens every semi-transparent edge of an icon. Only the public pixel
// accessors are used, so planar and alpha-first layouts are read correctly.
+ (NSBitmapImageRep *)PNGReadyCopyOf:(NSBitmapImageRep *)rep
{
    NSBitmapFormat format = [rep bitmapFormat];
    if (format & NSFloatingPointSamplesBitmapFormat) return nil;
    NSInteger bps = [rep bitsPerSample];
    NSInteger spp = [rep samplesPerPixel];
    if (spp > 5 || bps > 16) return nil;
    BOOL alpha = [rep hasAlpha];
    BOOL alphaFirst = alpha && (format & NSAlphaFirstBitmapFormat);
    BOOL premultiplied = alpha && !(format & NSAlphaNonpremultipliedBitmapFormat);
    NSInteger colours = alpha ? spp - 1 : spp;
    NSUInteger inMax = (1u << bps) - 1, outMax = 255;
    NSInteger w = [rep pixelsWide], h = [rep pixelsHigh];
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:w
                      pixelsHigh:h
                   bitsPerSample:8
                 samplesPerPixel:spp
                        hasAlpha:alpha
                        isPlanar:NO
                  colorSpaceName:[rep colorSpaceName]
                    bitmapFormat:alpha ? NSAlphaNonpremultipliedBitmapFormat : 0
                     bytesPerRow:0
                    bitsPerPixel:0];
    if (out == nil) return nil;
    NSUInteger in[5], px[5];
    for (NSInteger y = 0; y < h; y++) {
        for (NSInteger x = 0; x < w; x++) {
            [rep getPixel:in atX:x y:y];
            NSUInteger a = alpha ? in[alphaFirst ? 0 : spp - 1] : inMax;
            for (NSInteger i = 0; i < colours; i++) {
                NSUInteger c = in[alphaFirst ? i + 1 : i];
                if (premultiplied && a > 0 && a < inMax) {
                    c = (c * inMax + a / 2) / a;
                    if (c > inMax) c = inMax;
                }
                px[i] = (c * outMax + inMax / 2) / inMax;
            }
            if (alpha) px[colours] = (a * outMax + inMax / 2) / inMax;
            [out setPixel:px atX:x y:y];
        }
    }
    return out;
}

+ (BOOL)writePNGOfFirstImageInFile:(NSString *)srcPath toPath:(NSString *)dstPath
{
    // NSImageRep rather than NSImage: it decodes the file without a display
    // connection, and it keeps the pages in file order, so [0] is the page
    // the earlier ImageMagick-based packaging used.
    NSArray *reps = [NSImageRep imageRepsWithContentsOfFile:srcPath];
    if ([reps count] == 0) {
        NSLog(@"make_appimage: %@ is not an image format this system can read", srcPath);
        return NO;
    }
    id rep = [reps objectAtIndex:0];
    if (![rep isKindOfClass:[NSBitmapImageRep class]]) {
        NSLog(@"make_appimage: %@ is not a bitmap image", srcPath);
        return NO;
    }
    rep = [self PNGReadyCopyOf:rep];
    if (rep == nil) {
        NSLog(@"make_appimage: %@ has a pixel format the PNG conversion does not handle", srcPath);
        return NO;
    }
    NSData *png = [rep representationUsingType:NSPNGFileType properties:@{}];
    if (png == nil) {
        NSLog(@"make_appimage: could not encode %@ as PNG", srcPath);
        return NO;
    }
    NSError *err = nil;
    if (![png writeToFile:dstPath options:NSDataWritingAtomic error:&err]) {
        NSLog(@"make_appimage: could not write %@: %@", dstPath, err);
        return NO;
    }
    return YES;
}

@end
