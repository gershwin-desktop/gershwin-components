/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
 
#import "GWUtils.h"

@implementation GWUtils

+ (void)showErrorAlertWithTitle:(NSString *)title message:(NSString *)message
{
  NSDebugLLog(@"gwcomp", @"%@: %@", title, message);
  fprintf(stderr, "%s\n", [message UTF8String]);

  const char *noGui = getenv("APPWRAP_NO_GUI");
  if (noGui && strcmp(noGui, "1") == 0)
    return;

  if (!isatty(fileno(stderr)))
    return;

  Class NSAlertClass = NSClassFromString(@"NSAlert");
  if (NSAlertClass)
    {
      NSAlert *alert = [[NSAlertClass alloc] init];
      [alert setMessageText:title];
      [alert setInformativeText:message];
      [alert addButtonWithTitle:@"OK"];
      [alert runModal];
      [alert release];
    }
}

+ (NSString *)sanitizeFileName:(NSString *)name
{
  if (!name) return @"";
  // Replace path-separators with dashes
  NSString *s = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];

  // Replace control characters with spaces
  NSCharacterSet *ctrl = [NSCharacterSet controlCharacterSet];
  NSMutableString *out = [NSMutableString stringWithCapacity:[s length]];
  for (NSUInteger i = 0; i < [s length]; i++)
    {
      unichar c = [s characterAtIndex:i];
      if ([ctrl characterIsMember:c])
        {
          [out appendString:@" "];
        }
      else
        {
          [out appendFormat:@"%C", c];
        }
    }

  // Collapse whitespace and newlines to single spaces
  NSArray *parts = [out componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSPredicate *notEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
  NSArray *filtered = [parts filteredArrayUsingPredicate:notEmpty];
  NSString *result = [filtered componentsJoinedByString:@" "];
  // Trim leading/trailing whitespace
  result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

  if ([result length] == 0)
    return @"application";
  return result;
}

+ (NSString *)sanitizeExecCommand:(NSString *)command
{
  if (!command) { return nil; }

  NSDebugLog(@"Sanitizing Exec field: %@", command);
  NSMutableString *mutable = [NSMutableString stringWithString:command];

  // Remove common freedesktop field codes
  NSArray *codes = @[@"%U", @"%u", @"%F", @"%f", @"%i", @"%c", @"%k"];
  for (NSString *code in codes)
    {
      [mutable replaceOccurrencesOfString:code
                               withString:@""
                                  options:0
                                    range:NSMakeRange(0, [mutable length])];
    }

  // %% represents a literal percent
  [mutable replaceOccurrencesOfString:@"%%"
                           withString:@"%"
                              options:0
                                range:NSMakeRange(0, [mutable length])];

  // Collapse whitespace that may result from removals
  NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
  NSArray *parts = [mutable componentsSeparatedByCharactersInSet:ws];
  NSMutableArray *filtered = [NSMutableArray array];
  for (NSString *p in parts)
    {
      if ([p length] > 0) { [filtered addObject:p]; }
    }
  NSString *collapsed = [filtered componentsJoinedByString:@" "];
  NSDebugLog(@"Sanitized Exec field -> %@", collapsed);
  return collapsed;
}

+ (NSString *)findExecutableInPath:(NSString *)name
{
  if (!name || [name length] == 0) return nil;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *env = [[NSProcessInfo processInfo] environment];
  NSString *path = [env objectForKey:@"PATH"];
  if (!path) path = @"/usr/bin:/bin:/usr/local/bin";

  NSArray *components = [path componentsSeparatedByString:@":" ];
  for (NSString *dir in components)
    {
      NSString *candidate = [dir stringByAppendingPathComponent:name];
      if ([fm isExecutableFileAtPath:candidate])
        {
          NSDebugLog(@"Found executable '%@' at %@", name, candidate);
          return candidate;
        }
    }
  NSDebugLog(@"Executable '%@' not found in PATH", name);
  return nil;
}

+ (BOOL)rasterizeSVG:(NSString *)svgPath toPNG:(NSString *)pngPath size:(int)size
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDebugLog(@"Attempting to rasterize SVG %@ -> %@ at %dx%d using GNUstep if available", svgPath, pngPath, size, size);

  // First try pure-GNUstep approach using NSImage drawing
  @try
    {
      NSImage *img = [[NSImage alloc] initWithContentsOfFile:svgPath];
      if (img && [img isKindOfClass:[NSImage class]])
        {
          NSDebugLog(@"Loaded SVG into NSImage (size=%@). Rendering to %dx%d...", NSStringFromSize([img size]), size, size);

          // Create an alpha-enabled bitmap representation and draw into it using SourceOver
          NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                           pixelsWide:size
                                                                           pixelsHigh:size
                                                                        bitsPerSample:8
                                                                      samplesPerPixel:4
                                                                             hasAlpha:YES
                                                                             isPlanar:NO
                                                                       colorSpaceName:NSDeviceRGBColorSpace
                                                                         bytesPerRow:0
                                                                          bitsPerPixel:0];

          NSDebugLog(@"Created NSBitmapImageRep for rasterization (hasAlpha=%d)", [rep hasAlpha]);

          if (rep)
            {
              NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
              [NSGraphicsContext saveGraphicsState];
              [NSGraphicsContext setCurrentContext:ctx];

              // Clear to transparent first
              [[NSColor clearColor] set];
              NSRectFill(NSMakeRect(0, 0, size, size));

              // Draw image scaled to target using SourceOver so alpha is preserved
              [img drawInRect:NSMakeRect(0,0,size,size) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];

              [NSGraphicsContext restoreGraphicsState];

              NSData *pngData = [rep representationUsingType:NSPNGFileType properties:nil];
              if (pngData && [pngData writeToFile:pngPath atomically:YES])
                {
                  NSDebugLog(@"GNUstep rasterization succeeded: %@", pngPath);
                  [rep release];
                  [img release];
                  return YES;
                }
              else
                {
                  NSDebugLog(@"GNUstep rasterization produced no data or failed to write to %@", pngPath);
                }
              [rep release];
            }
          [img release];
        }
    }
  @catch (NSException *ex)
    {
      NSDebugLog(@"GNUstep rasterization failed with exception: %@", ex);
    }

  // If we get here, fallback to command-line tools found on PATH
  // rsvg-convert only: ImageMagick is not installed on Gershwin systems any
  // more (its dependencies cost the live images hundreds of MB), and for SVG
  // it delegated to librsvg anyway, so it never rendered anything differently.
  NSArray *tools = @[@"rsvg-convert"];
  for (NSString *t in tools)
    {
      NSString *exe = [self findExecutableInPath:t];
      if (!exe) continue;

      NSDebugLog(@"Using external tool '%@' at %@ to rasterize", t, exe);
      NSTask *task = [[NSTask alloc] init];

      if ([t isEqualToString:@"rsvg-convert"]) 
        {
          [task setLaunchPath:exe];
          // Request transparent background explicitly. -a, because with both
          // -w and -h rsvg-convert otherwise stretches a non-square icon to
          // fill the square instead of fitting it in.
          [task setArguments:@[@"-a", @"-w", [NSString stringWithFormat:@"%d", size], @"-h", [NSString stringWithFormat:@"%d", size], @"-b", @"transparent", @"-o", pngPath, svgPath]];
        }

      @try
        {
          [task launch];
          [task waitUntilExit];
          int status = [task terminationStatus];
          [task release];
          if (status == 0 && [fm fileExistsAtPath:pngPath])
            {
              NSDebugLog(@"External tool '%@' rasterized SVG successfully to %@", t, pngPath);
              return YES;
            }
          else
            {
              NSDebugLog(@"External tool '%@' failed (status %d)", t, status);
            }
        }
      @catch (NSException *e)
        {
          NSDebugLLog(@"gwcomp", @"Failed to run '%@' due to exception: %@", t, e);
        }
    }

  NSDebugLog(@"All rasterization methods failed for %@", svgPath);
  return NO;
}

+ (NSArray *)extensionsForMIMEType:(NSString *)mimeType
{
  if (!mimeType) return nil;

  NSDebugLog(@"Looking up extensions for MIME type: %@", mimeType);

  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableSet *exts = [NSMutableSet set];


  NSArray *pkgDirs = @[@"/usr/share/mime/packages",
                       @"/usr/local/share/mime/packages",
                       [NSString stringWithFormat:@"%@/.local/share/mime/packages", NSHomeDirectory()]];
  for (NSString *dir in pkgDirs)
    {
      if (![fm fileExistsAtPath:dir]) continue;
      NSDebugLog(@"Scanning mime package dir: %@", dir);
      NSDirectoryEnumerator *e = [fm enumeratorAtPath:dir];
      NSString *file;
      while ((file = [e nextObject]))
        {
          NSString *path = [dir stringByAppendingPathComponent:file];
          NSError *readErr = nil;
          NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readErr];
          if (!content)
            {
              NSDebugLog(@"Failed reading %@: %@", path, [readErr localizedDescription]);
              continue;
            }

          // Look for the specific mime-type tag
          NSString *searchTag1 = [NSString stringWithFormat:@"<mime-type type=\"%@\"", mimeType];
          NSString *searchTag2 = [NSString stringWithFormat:@"<mime-type type=\'%@\'", mimeType];

          NSRange foundRange = [content rangeOfString:searchTag1];
          if (foundRange.location == NSNotFound)
            foundRange = [content rangeOfString:searchTag2];

          if (foundRange.location != NSNotFound)
            {
              // Limit to the mime-type section (until </mime-type> or next <mime-type)
              NSRange tailRange = NSMakeRange(foundRange.location, [content length] - foundRange.location);
              NSRange endRange = [content rangeOfString:@"</mime-type>" options:0 range:tailRange];
              NSUInteger scanLength = (endRange.location != NSNotFound) ? (endRange.location - foundRange.location) : (tailRange.length);
              NSString *section = [content substringWithRange:NSMakeRange(foundRange.location, scanLength)];

              // Find pattern=\"*.ext\" occurrences using regex
              NSError *reErr = nil;
              NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"pattern\\s*=\\s*['\"](\\*\\.[^'\"]+)['\"]" options:NSRegularExpressionCaseInsensitive error:&reErr];
              if (re && !reErr)
                {
                  NSArray *matches = [re matchesInString:section options:0 range:NSMakeRange(0, [section length])];
                  for (NSTextCheckingResult *m in matches)
                    {
                      NSRange r = [m rangeAtIndex:1];
                      NSString *pat = [section substringWithRange:r]; // like \"*.txt\" or \"*.tar.gz\"
                      if ([pat hasPrefix:@"*."] && [pat length] > 2)
                        {
                          NSString *ext = [pat substringFromIndex:2];
                          [exts addObject:ext];
                        }
                    }
                }
            }
        }

      if ([exts count] > 0)
        {
          NSDebugLog(@"Found extensions via mime packages: %@", exts);
          return [[exts allObjects] sortedArrayUsingSelector:@selector(compare:)];
        }
    }

  // 2) Try globs2 / globs files as a fallback
  NSArray *globsFiles = @[@"/usr/share/mime/globs2",
                          @"/usr/local/share/mime/globs2",
                          [NSString stringWithFormat:@"%@/.local/share/mime/globs2", NSHomeDirectory()],
                          @"/usr/share/mime/globs",
                          @"/usr/local/share/mime/globs"];

  for (NSString *gf in globsFiles)
    {
      if (![fm fileExistsAtPath:gf]) continue;
      NSError *gErr = nil;
      NSString *content = [NSString stringWithContentsOfFile:gf encoding:NSUTF8StringEncoding error:&gErr];
      if (!content)
        {
          NSDebugLog(@"Failed reading %@: %@", gf, [gErr localizedDescription]);
          continue;
        }

      NSDebugLog(@"Scanning globs file: %@", gf);
      NSArray *lines = [content componentsSeparatedByString:@"\n"];
      for (NSString *line in lines)
        {
          if ([line rangeOfString:mimeType].location == NSNotFound) continue;

          // Find any token with *.
          NSScanner *sc = [NSScanner scannerWithString:line];
          while (![sc isAtEnd])
            {
              [sc scanUpToString:@"*." intoString:NULL];
              if ([sc scanString:@"*." intoString:NULL])
                {
                  // read until non-word or whitespace
                  NSMutableString *acc = [NSMutableString string];
                  unichar ch;
                  while (![sc isAtEnd])
                    {
                      ch = [line characterAtIndex:sc.scanLocation];
                      if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch] || ch == '.')
                        {
                          [acc appendFormat:@"%c", ch];
                          sc.scanLocation += 1;
                        }
                      else
                        break;
                    }
                  if ([acc length] > 0)
                    {
                      [exts addObject:acc];
                    }
                }
              else
                break;
            }
        }

      if ([exts count] > 0)
        {
          NSDebugLog(@"Found extensions via globs file %@: %@", gf, exts);
          return [[exts allObjects] sortedArrayUsingSelector:@selector(compare:)];
        }
    }

  // 3) Fallback to small built-in mapping (only used if system DB not available)
  NSDebugLog(@"No shared-mime-info entries found for %@; falling back to built-in mapping", mimeType);
  static NSDictionary *mimeMap = nil;
  if (!mimeMap)
    {
      mimeMap = [[NSDictionary alloc] initWithObjectsAndKeys:
                 @[@"txt"], @"text/plain",
                 @[@"html", @"htm"], @"text/html",
                 @[@"png"], @"image/png",
                 @[@"jpg", @"jpeg"], @"image/jpeg",
                 @[@"gif"], @"image/gif",
                 @[@"pdf"], @"application/pdf",
                 @[@"zip"], @"application/zip",
                 @[@"tar"], @"application/x-tar",
                 @[@"7z"], @"application/x-7z-compressed",
                 @[@"json"], @"application/json",
                 @[@"xml"], @"application/xml",
                 @[@"mp3"], @"audio/mpeg",
                 @[@"mp4"], @"video/mp4",
                 nil];
    }

  NSArray *fb = [mimeMap objectForKey:mimeType];
  if (fb && [fb count] > 0)
    return fb;

  // Final fallback: use subtype
  NSArray *parts = [mimeType componentsSeparatedByString:@"/"];
  if ([parts count] > 1)
    {
      NSString *subtype = [[parts lastObject] lowercaseString];
      NSRange plus = [subtype rangeOfString:@"+"];
      if (plus.location != NSNotFound)
        subtype = [subtype substringFromIndex:plus.location + 1];
      if ([subtype length] > 0) return [NSArray arrayWithObject:subtype];
    }

  return nil;
}

@end
