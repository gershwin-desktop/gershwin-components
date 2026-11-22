/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SCFileNamer.h"

@implementation SCFileNamer
{
  NSString *_directory;
  NSString *_prefix;
  NSString *_suffix;
  NSUInteger _digits;
  NSUInteger _next;
}

- (instancetype) initWithDirectory: (NSString *)directory
                           pattern: (NSString *)pattern
                         extension: (NSString *)extension
{
  self = [super init];
  if (self)
    {
      NSRange hashes = [pattern rangeOfString: @"#"];
      NSUInteger end;

      if (hashes.location == NSNotFound)
        {
          pattern = [pattern stringByAppendingString: @"-####"];
          hashes = [pattern rangeOfString: @"#"];
        }
      end = hashes.location;
      while (end < [pattern length] && [pattern characterAtIndex: end] == '#')
        {
          end++;
        }
      _directory = [directory copy];
      _prefix = [pattern substringToIndex: hashes.location];
      /* Not stringByAppendingPathExtension: it refuses an empty suffix */
      _suffix = [NSString stringWithFormat: @"%@.%@",
                          [pattern substringFromIndex: end], extension];
      _digits = end - hashes.location;
      _next = 0;
    }
  return self;
}

- (NSUInteger) highestExistingNumber
{
  NSArray *files = [[NSFileManager defaultManager]
                     contentsOfDirectoryAtPath: _directory error: NULL];
  NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet]
                                invertedSet];
  NSUInteger highest = 0;

  for (NSString *file in files)
    {
      NSString *middle;

      if ([file length] <= [_prefix length] + [_suffix length]
          || ![file hasPrefix: _prefix] || ![file hasSuffix: _suffix])
        {
          continue;
        }
      middle = [file substringWithRange:
        NSMakeRange([_prefix length],
                    [file length] - [_prefix length] - [_suffix length])];
      if ([middle rangeOfCharacterFromSet: nonDigits].location == NSNotFound)
        {
          highest = MAX(highest, (NSUInteger)[middle longLongValue]);
        }
    }
  return highest;
}

- (NSString *) nextPath
{
  NSString *name;

  /* Rescan every time: the user may have added files between scans */
  _next = MAX(_next, [self highestExistingNumber]) + 1;
  name = [NSString stringWithFormat: @"%@%0*lu%@", _prefix, (int)_digits,
                   (unsigned long)_next, _suffix];
  return [_directory stringByAppendingPathComponent: name];
}

@end
