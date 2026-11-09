/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Turns a bundle's icon into the PNG an AppDir needs, with the image formats
// AppKit reads itself (TIFF, PNG, JPEG, GIF; ICNS when libs-gui was built with
// libicns), so packaging does not depend on an external image converter.
@interface IconConverter : NSObject

// Writes the first image in srcPath (the first page of a multi-page TIFF, as
// "convert file[0]" took it) as an RGBA PNG to dstPath. NO, with the reason
// logged, if the file cannot be read as a bitmap or the PNG cannot be written.
+ (BOOL)writePNGOfFirstImageInFile:(NSString *)srcPath toPath:(NSString *)dstPath;

@end
