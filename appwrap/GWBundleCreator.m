/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
 
#import "GWBundleCreator.h"
#import "DesktopFileParser.h"
#import "GWDocumentIcon.h"
#import "GWUtils.h"

@implementation GWBundleCreator

- (BOOL)createBundleFromDesktopFile:(NSString *)desktopPath
                           outputDir:(NSString *)outputDir
{
  // Parse the desktop file
  NSDebugLog(@"Starting bundle creation from desktop file: %@", desktopPath);
  DesktopFileParser *parser = [[DesktopFileParser alloc] initWithFile:desktopPath];
  if (!parser)
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to parse desktop file: %@", desktopPath];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  // Get application metadata
  NSString *appName = [parser stringForKey:@"Name"];
  NSString *execCommand = [parser stringForKey:@"Exec"];
  NSString *iconName = [parser stringForKey:@"Icon"];

  NSDebugLog(@"Parsed desktop file entries: Name=%@ Exec=%@ Icon=%@", appName, execCommand, iconName);

  if (!appName || !execCommand)
    {
      NSString *msg = @"Invalid desktop file: missing Name or Exec";
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      [parser release];
      return NO;
    }

  // Use application name as bundle name, but sanitize it for filesystem safety
  NSString *bundleName = [GWUtils sanitizeFileName:appName];

  // Create the bundle path
  NSString *appPath = [NSString stringWithFormat:@"%@/%@.app", 
                       outputDir, bundleName];

  // Resolve icon path if provided
  NSString *resolvedIconPath = nil;
  if (iconName && [iconName length] > 0)
    {
      resolvedIconPath = [self resolveIconPath:iconName];
    }

  // If no icon was specified or resolution failed, try a set of generic fallback icons
  if (!resolvedIconPath)
    {
      NSArray *genericFallbacks = @[@"dialog-information", @"application", @"preferences-system", @"dialog-warning", @"dialog-error", @"notification", @"utilities-system-monitor"];
      NSDebugLog(@"No specific icon resolved for %@; trying generic fallbacks: %@", appName, genericFallbacks);
      for (NSString *gname in genericFallbacks)
        {
          NSString *p = [self resolveIconPath:gname];
          if (p)
            {
              resolvedIconPath = p;
              NSDebugLog(@"Using generic fallback icon '%@' -> %@", gname, p);
              break;
            }
        }
      if (!resolvedIconPath)
        {
          NSDebugLog(@"No icon could be resolved for %@ (including generic fallbacks)", appName);
        }
    }

  // Create bundle structure
  NSDebugLog(@"Creating bundle structure at %@", appPath);
  if (![self createBundleStructure:appPath withAppName:bundleName])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create bundle structure at %@", appPath];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      [parser release];
      return NO;
    }

  // Create the launcher script with the full Exec command; sanitize script name for safety
  NSDebugLog(@"Creating launcher script (name: %@) with Exec: %@", bundleName, execCommand);
  if (![self createLauncherScript:appPath 
                      execCommand:execCommand
                        iconPath:resolvedIconPath
                        scriptName:bundleName])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create launcher script for %@", appName];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      [parser release];
      return NO;
    }

  // Copy icon if found and get the actual copied filename
  NSString *copiedIconFilename = nil;
  if (resolvedIconPath)
    {
      NSDebugLog(@"Copying icon from %@ into bundle resources", resolvedIconPath);
      copiedIconFilename = [self copyIconToBundle:resolvedIconPath
                                  toBundleResources:[NSString stringWithFormat:@"%@/Resources", appPath]
                                           appName:bundleName];
      NSDebugLog(@"Resulting icon filename in bundle: %@", copiedIconFilename);
    }
  else
    {
      NSDebugLog(@"No icon resolved; skipping icon copy and Info.plist icon entry will be omitted");
    }

  // Create the Info.plist with the actual copied icon filename
  NSDebugLog(@"Creating Info.plist (appName=%@, exec=%@, icon=%@)", appName, execCommand, copiedIconFilename);
  if (![self createInfoPlist:appPath 
                 desktopInfo:parser
                     appName:appName
                   execPath:execCommand
                   iconFilename:copiedIconFilename])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create Info.plist for %@", appName];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      [parser release];
      return NO;
    }

  NSDebugLLog(@"gwcomp", @"Successfully created application bundle: %@", appPath);
  [parser release];
  return YES;
}

- (BOOL)createBundleFromCommand:(NSString *)command
                        appName:(NSString *)appName
                        iconPath:(NSString *)iconPath
                        outputDir:(NSString *)outputDir
{
  if (!command || !appName || !outputDir) return NO;
  NSString *sanAppName = [GWUtils sanitizeFileName:appName];
  NSDebugLog(@"Starting bundle creation from command: %@ (appName=%@)", command, sanAppName);

  NSString *appPath = [NSString stringWithFormat:@"%@/%@.app", outputDir, sanAppName];

  // Create bundle structure
  if (![self createBundleStructure:appPath withAppName:sanAppName])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create bundle structure at %@", appPath];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  // Create the launcher script with the provided command
  if (![self createLauncherScript:appPath execCommand:command iconPath:iconPath scriptName:sanAppName])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create launcher script for %@", appName];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  // Copy icon if provided and get the resulting filename
  NSString *copiedIconFilename = nil;
  if (iconPath && [iconPath length] > 0)
    {
      copiedIconFilename = [self copyIconToBundle:iconPath toBundleResources:[NSString stringWithFormat:@"%@/Resources", appPath] appName:sanAppName];
      NSDebugLog(@"Resulting icon filename in bundle: %@", copiedIconFilename);
    }

  // Create Info.plist
  if (![self createInfoPlist:appPath desktopInfo:nil appName:appName execPath:command iconFilename:copiedIconFilename])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create Info.plist for %@", appName];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  NSDebugLLog(@"gwcomp", @"Successfully created application bundle: %@", appPath);
  return YES;
}

- (BOOL)createBundleStructure:(NSString *)appPath
                  withAppName:(NSString *)appName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;

  // Create the .app directory
  if (![fm createDirectoryAtPath:appPath 
        withIntermediateDirectories:YES 
                         attributes:nil 
                              error:&error])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create app directory: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  // Create Resources subdirectory
  NSString *resourcesPath = [NSString stringWithFormat:@"%@/Resources", appPath];
  if (![fm createDirectoryAtPath:resourcesPath 
        withIntermediateDirectories:YES 
                         attributes:nil 
                              error:&error])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to create Resources directory: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  return YES;
}

- (BOOL)createInfoPlist:(NSString *)appPath
            desktopInfo:(DesktopFileParser *)parser
                appName:(NSString *)appName
              execPath:(NSString *)execPath
          iconFilename:(NSString *)iconFilename
{
  NSMutableDictionary *infoPlist = [NSMutableDictionary dictionary];

  [infoPlist setObject:@"8.0" forKey:@"NSAppVersion"];
  [infoPlist setObject:appName forKey:@"NSExecutable"];
  [infoPlist setObject:appName forKey:@"NSApplicationName"];
  [infoPlist setObject:@"1.0" forKey:@"NSApplicationVersion"];
  [infoPlist setObject:appName forKey:@"CFBundleName"];

  // Try to get version from desktop file
  NSString *version = [parser stringForKey:@"Version"];
  if (version)
    {
      [infoPlist setObject:version forKey:@"NSApplicationVersion"];
    }

  // Set icon name if an icon was successfully copied
  if (iconFilename && [iconFilename length] > 0)
    {
      // Use the full filename with extension
      NSString *iconNameWithExtension = [iconFilename lastPathComponent];
      [infoPlist setObject:iconNameWithExtension forKey:@"NSIcon"];
    }

  /* Workspace and the Dock find a wrapped program's windows by their class,
   * never by title, so a program whose class differs from its name (Claude
   * Desktop: com.anthropic.Claude) would otherwise get no running dot and
   * could not be raised from the Dock after a Workspace restart. */
  NSString *wmClass = [parser stringForKey:@"StartupWMClass"];
  if ([wmClass length] > 0)
    {
      [infoPlist setObject:wmClass forKey:@"GSX11WindowClass"];
    }

  // Add document types from desktop MimeType key, if present
  NSArray *mimeTypes = [parser arrayForKey:@"MimeType"];
  if (mimeTypes && [mimeTypes count] > 0)
    {
      NSDebugLog(@"Found MimeType entries in desktop file: %@", mimeTypes);
      NSMutableArray *docTypes = [NSMutableArray array];
      for (NSString *mt in mimeTypes)
        {
          if (![mt length]) continue;
          NSMutableDictionary *dt = [NSMutableDictionary dictionary];
          NSString *typeName = mt;
          [dt setObject:typeName forKey:@"CFBundleTypeName"];
          [dt setObject:@"Editor" forKey:@"CFBundleTypeRole"];

          NSArray *exts = [GWUtils extensionsForMIMEType:mt];
          if (exts && [exts count] > 0)
            {
              NSDebugLog(@"Mapping MIME %@ -> extensions %@", mt, exts);
              [dt setObject:exts forKey:@"CFBundleTypeExtensions"];
            }
          else
            {
              NSDebugLog(@"No extensions mapped for MIME %@; adding type without extensions", mt);
            }

          if (iconFilename && [iconFilename length] > 0)
            {
              // Create a document-specific icon by compositing the generic document image
              // with a small version of the app's icon so files of this type are visually
              // associated with the app. The icon will be written into the bundle Resources
              // and the resulting filename is stored in CFBundleTypeIconFile.
              NSString *resourcesPath = [NSString stringWithFormat:@"%@/Resources", appPath];
              NSString *createdDocIcon = [GWDocumentIcon createDocumentIconInResources:resourcesPath
                                                                               appName:appName
                                                                      appIconFilename:[iconFilename lastPathComponent]
                                                                               mimeType:mt
                                                                               typeName:typeName
                                                                                   size:256];
              if (createdDocIcon)
                {
                  [dt setObject:createdDocIcon forKey:@"CFBundleTypeIconFile"];
                }
              else
                {
                  // Fallback to app icon if doc icon creation failed
                  [dt setObject:[iconFilename lastPathComponent] forKey:@"CFBundleTypeIconFile"];
                }
            }

          [docTypes addObject:dt];
        }

      if ([docTypes count] > 0)
        {
          [infoPlist setObject:docTypes forKey:@"CFBundleDocumentTypes"];
          NSDebugLog(@"Added CFBundleDocumentTypes to Info.plist: %@", docTypes);
        }
    }

  // Create the plist file
  NSString *plistPath = [NSString stringWithFormat:@"%@/Resources/Info.plist", appPath];
  BOOL ok = [infoPlist writeToFile:plistPath atomically:YES];
  if (!ok)
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to write Info.plist to %@", plistPath];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
    }
  else
    {
      NSDebugLog(@"Wrote Info.plist to %@", plistPath);
    }
  return ok;
}

- (BOOL)createLauncherScript:(NSString *)appPath
                 execCommand:(NSString *)command
                 iconPath:(NSString *)iconPath
                 scriptName:(NSString *)scriptName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  // Use the provided scriptName (full appName with spaces) for the executable file
  NSString *launcherPath = [NSString stringWithFormat:@"%@/%@", appPath, scriptName];

  // Sanitize Exec= field codes (%U, %u, %F, %f, %i, %c, %k) and %% → %
  NSDebugLog(@"Sanitizing Exec command for launcher: %@", command);
  NSString *sanitized = [GWUtils sanitizeExecCommand:command];
  if (!sanitized || [sanitized length] == 0)
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to sanitize Exec command: %@", command];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  NSDebugLog(@"Sanitized Exec command: %@", sanitized);

  // Create the launcher script using the sanitized command.
  // We filter out -GSFilePath because non-GNUstep apps don't understand it.
  NSString *script = [NSString stringWithFormat:
    @"#!/bin/sh\n"
    @"# Auto-generated launcher script\n"
    @"for arg do\n"
    @"  shift\n"
    @"  [ \"$arg\" = \"-GSFilePath\" ] && continue\n"
    @"  set -- \"$@\" \"$arg\"\n"
    @"done\n"
    @"exec %@ \"$@\"\n",
    sanitized];

  NSError *error = nil;
  if (![script writeToFile:launcherPath 
                 atomically:YES 
                   encoding:NSUTF8StringEncoding 
                      error:&error])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to write launcher script: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  // Make the script executable
  if (![fm setAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0755]
                                                     forKey:NSFilePosixPermissions]
            ofItemAtPath:launcherPath error:&error])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to set permissions on launcher script: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Error" message:msg];
      return NO;
    }

  NSDebugLog(@"Created launcher script at %@", launcherPath);
  return YES;
}

- (NSString *)resolveIconPath:(NSString *)iconName
{
  NSFileManager *fm = [NSFileManager defaultManager];
  if (!iconName || [iconName length] == 0)
    {
      NSDebugLog(@"resolveIconPath: called with empty iconName");
      return nil;
    }

  NSDebugLog(@"Resolving icon path for: '%@'", iconName);

  // If it's an absolute path and exists, use it directly
  if ([iconName hasPrefix:@"/"] && [fm fileExistsAtPath:iconName])
    {
      NSDebugLog(@"Icon provided as absolute path and exists: %@", iconName);
      return iconName;
    }

  // Candidate structure: @{ @"path": path, @"ext": ext, @"score": @(score) }
  NSMutableArray *candidates = [NSMutableArray array];

  // Extensions to consider (ordered by preference)
  NSArray *extensions = @[@".png", @".svg", @".xpm", @".ico", @".gif", @".jpg", @".jpeg", @""];

  // Build a list of directories to search (themes + pixmaps + local)
  NSMutableArray *iconBaseDirs = [NSMutableArray arrayWithObjects:
                                  @"/usr/share/icons",
                                  @"/usr/local/share/icons",
                                  @"/usr/share/pixmaps",
                                  @"/usr/local/share/pixmaps",
                                  [NSString stringWithFormat:@"%@/.local/share/icons", NSHomeDirectory()],
                                  [NSString stringWithFormat:@"%@/.local/share/pixmaps", NSHomeDirectory()],
                                  nil];

  // Also add top-level hicolor locations for quick checks
  NSArray *quickPaths = @[
    @"/usr/share/icons/hicolor",
    @"/usr/local/share/icons/hicolor",
    [NSString stringWithFormat:@"%@/.local/share/icons/hicolor", NSHomeDirectory()]
  ];

  // 1) Quick exact checks (theme common sizes + pixmaps)
  NSArray *quickSizePaths = @[@"256x256/apps", @"128x128/apps", @"96x96/apps", @"64x64/apps", @"48x48/apps", @"32x32/apps", @"24x24/apps"];
  for (NSString *base in quickPaths)
    {
      for (NSString *sizeSub in quickSizePaths)
        {
          for (NSString *ext in extensions)
            {
              NSString *cand = [NSString stringWithFormat:@"%@/%@/%@%@", base, sizeSub, iconName, ext];
              if ([fm fileExistsAtPath:cand])
                {
                  NSDebugLog(@"Quick-match found candidate: %@", cand);
                  [candidates addObject:@{@"path": cand, @"ext": ext}];
                }
            }
        }
    }

  // 2) Recursive search in iconBaseDirs for exact basename matches
  for (NSString *base in iconBaseDirs)
    {
      if (![fm fileExistsAtPath:base]) continue;
      NSDebugLog(@"Searching base icon dir: %@", base);
      NSDirectoryEnumerator *e = [fm enumeratorAtPath:base];
      NSString *file;
      while ((file = [e nextObject]))
        {
          NSString *lowerFile = [file lowercaseString];
          NSString *lowerIcon = [iconName lowercaseString];

          // Check if file ends with iconName + ext or equals iconName
          for (NSString *ext in extensions)
            {
              NSString *target = nil;
              if ([ext length] > 0)
                target = [NSString stringWithFormat:@"%@%@", iconName, ext];
              else
                target = iconName;

              if ([[file lastPathComponent] isEqualToString:target] || [[file lastPathComponent] isEqualToString:[target lowercaseString]] || [[file lastPathComponent] isEqualToString:[target uppercaseString]])
                {
                  NSString *full = [base stringByAppendingPathComponent:file];
                  NSDebugLog(@"Found candidate by basename match: %@", full);
                  [candidates addObject:@{@"path": full, @"ext": ext}];
                }
            }

          // quick substring fuzzy match (e.g., iconName-symbolic, iconName-16)
          if ([lowerFile rangeOfString:lowerIcon].location != NSNotFound)
            {
              NSString *full = [base stringByAppendingPathComponent:file];
              NSDebugLog(@"Found fuzzy candidate (substring match): %@", full);
              [candidates addObject:@{@"path": full, @"ext": [[file pathExtension] length] ? [@"." stringByAppendingString:[file pathExtension]] : @""}];
            }
        }

      if ([candidates count] > 0)
        {
          NSDebugLog(@"Stopping search at base %@ because candidates were found", base);
          break;
        }
    }

  // If no candidates yet, try more aggressive fuzzy search across installed themes
  if ([candidates count] == 0)
    {
      NSDebugLog(@"No direct candidates found; performing aggressive fuzzy search (case-insensitive substring) across icon dirs");
      for (NSString *base in iconBaseDirs)
        {
          if (![fm fileExistsAtPath:base]) continue;
          NSDirectoryEnumerator *e = [fm enumeratorAtPath:base];
          NSString *file;
          while ((file = [e nextObject]))
            {
              NSString *lowerFile = [file lowercaseString];
              NSString *lowerIcon = [iconName lowercaseString];
              if ([lowerFile rangeOfString:lowerIcon].location != NSNotFound)
                {
                  NSString *full = [base stringByAppendingPathComponent:file];
                  NSDebugLog(@"Aggressive fuzzy candidate: %@", full);
                  [candidates addObject:@{@"path": full, @"ext": [[file pathExtension] length] ? [@"." stringByAppendingString:[file pathExtension]] : @""}];
                }
            }
        }
    }

  if ([candidates count] == 0)
    {
      NSDebugLog(@"No icon candidates found for '%@' after extensive search and generic fallbacks", iconName);
      return nil;
    }

  // Score candidates and pick the best one
  NSMutableArray *scored = [NSMutableArray array];
  for (NSDictionary *c in candidates)
    {
      NSString *path = [c objectForKey:@"path"];
      NSString *ext = [[path pathExtension] lowercaseString];
      int score = 0;

      // Extension preference
      if ([ext isEqualToString:@"png"]) score += 100;
      else if ([ext isEqualToString:@"svg"]) score += 90;
      else if ([ext isEqualToString:@"xpm"]) score += 70;
      else if ([ext isEqualToString:@"ico"]) score += 60;
      else if ([ext isEqualToString:@"gif"]) score += 50;
      else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) score += 40;
      else if ([ext length] == 0) score += 10;

      // Theme boost for hicolor
      if ([path rangeOfString:@"hicolor" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 50;

      // Pixmaps directory moderate boost
      if ([path rangeOfString:@"/pixmaps" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 20;

      // Prefer non-symbolic icons a bit
      if ([[path lastPathComponent] rangeOfString:@"-symbolic" options:NSCaseInsensitiveSearch].location != NSNotFound)
        score -= 30;

      // Parse size in path like 256x256
      NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+)x([0-9]+)" options:0 error:NULL];
      NSTextCheckingResult *m = [re firstMatchInString:path options:0 range:NSMakeRange(0, [path length])];
      if (m && [m numberOfRanges] >= 3)
        {
          NSString *s1 = [path substringWithRange:[m rangeAtIndex:1]];
          int sizeVal = [s1 intValue];
          score += sizeVal; // larger size -> higher score
        }

      // Scalable icons should be treated as high quality
      if ([path rangeOfString:@"scalable" options:NSCaseInsensitiveSearch].location != NSNotFound)
        score += 200;

      [scored addObject:@{@"path": path, @"score": @(score)}];
    }

  // Log candidate scores
  NSDebugLog(@"Icon candidates and scores for '%@':", iconName);
  for (NSDictionary *s in scored)
    {
      NSDebugLog(@"  %@ -> %@", [s objectForKey:@"path"], [s objectForKey:@"score"]);
    }

  // Pick the candidate with the highest score
  NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"score" ascending:NO];
  NSArray *sorted = [scored sortedArrayUsingDescriptors:@[sd]];
  NSDictionary *best = [sorted objectAtIndex:0];
  NSString *bestPath = [best objectForKey:@"path"];

  NSDebugLog(@"Selected icon for '%@': %@ (reason: highest score)", iconName, bestPath);
  return bestPath;
}

- (NSString *)copyIconToBundle:(NSString *)iconPath
                toBundleResources:(NSString *)resourcesPath
                       appName:(NSString *)appName
{
  if (!iconPath)
    return nil;

  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;

  // Check if the icon file exists and has non-zero size
  NSDictionary *fileAttrs = [fm attributesOfItemAtPath:iconPath error:&error];
  if (!fileAttrs)
    {
      NSString *msg = [NSString stringWithFormat:@"Could not read icon file attributes: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Icon error" message:msg];
      return nil;
    }

  unsigned long long fileSize = [fileAttrs fileSize];
  if (fileSize == 0)
    {
      NSString *msg = [NSString stringWithFormat:@"Icon file is empty (0 bytes): %@", iconPath];
      [GWUtils showErrorAlertWithTitle:@"Icon error" message:msg];
      return nil;
    }

  // Get the icon file extension
  NSString *iconExt = [[iconPath pathExtension] lowercaseString];
  if ([iconExt length] == 0)
    {
      iconExt = @"png";
    }

  // If the icon is an SVG, try to rasterize to PNG (256x256)
  if ([iconExt isEqualToString:@"svg"])
    {
      NSString *bundleIconPath = [NSString stringWithFormat:@"%@/%@.%@",
                                 resourcesPath, appName, @"png"];

      // Attempt GNUstep rasterization or external tool fallback
      if ([GWUtils rasterizeSVG:iconPath toPNG:bundleIconPath size:256])
        {
          NSDictionary *copiedAttrs = [fm attributesOfItemAtPath:bundleIconPath error:&error];
          if (copiedAttrs && [copiedAttrs fileSize] > 0)
            {
              NSDebugLog(@"Rasterized SVG and wrote PNG to bundle as %@", [bundleIconPath lastPathComponent]);
              return [bundleIconPath lastPathComponent];
            }
          else
            {
              NSDebugLog(@"Rasterization produced empty file or failed to write: %@", bundleIconPath);
            }
        }
      else
        {
          NSDebugLog(@"Rasterization failed for %@; will try to copy original SVG into bundle as fallback", iconPath);
        }

      // As a fallback, copy the original SVG into the resources
      NSString *bundleSVGPath = [NSString stringWithFormat:@"%@/%@.%@", resourcesPath, appName, @"svg"];
      if ([fm copyItemAtPath:iconPath toPath:bundleSVGPath error:&error])
        {
          NSDictionary *copiedAttrs = [fm attributesOfItemAtPath:bundleSVGPath error:&error];
          if (copiedAttrs && [copiedAttrs fileSize] > 0)
            {
              NSDebugLog(@"Copied SVG fallback into bundle as %@", [bundleSVGPath lastPathComponent]);
              return [bundleSVGPath lastPathComponent];
            }
          else
            {
              NSDebugLog(@"Copied SVG fallback file is empty, removing: %@", bundleSVGPath);
              [fm removeItemAtPath:bundleSVGPath error:NULL];
              return nil;
            }
        }
      else
        {
          NSDebugLog(@"Failed to copy SVG fallback into bundle: %@", [error localizedDescription]);
          return nil;
        }
    }

  // Non-SVG: Create the destination path with the extension
  NSString *bundleIconPath = [NSString stringWithFormat:@"%@/%@.%@",
                             resourcesPath, appName, iconExt];

  // Copy icon to bundle Resources
  if (![fm copyItemAtPath:iconPath toPath:bundleIconPath error:&error])
    {
      NSString *msg = [NSString stringWithFormat:@"Failed to copy icon: %@", [error localizedDescription]];
      [GWUtils showErrorAlertWithTitle:@"Icon error" message:msg];
      return nil;
    }

  // Verify the copied file is not empty
  NSDictionary *copiedAttrs = [fm attributesOfItemAtPath:bundleIconPath error:&error];
  if (!copiedAttrs || [copiedAttrs fileSize] == 0)
    {
      NSString *msg = [NSString stringWithFormat:@"Copied icon file is empty, removing: %@", bundleIconPath];
      [GWUtils showErrorAlertWithTitle:@"Icon error" message:msg];
      [fm removeItemAtPath:bundleIconPath error:NULL];
      return nil;
    }

  NSDebugLog(@"Copied icon to bundle as %@", [bundleIconPath lastPathComponent]);
  return [bundleIconPath lastPathComponent];
}

@end
