/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
/* Prints the general pasteboard's plain text and RTF size for the user it
   runs as (the slot user, never the desktop user), for copy_check.sh. */
#import <AppKit/AppKit.h>
int main(int argc, char **argv)
{
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    // --clear empties it first, so a copy that writes nothing cannot pass on
    // what an earlier run left there.
    if (argc > 1 && strcmp(argv[1], "--clear") == 0) {
      [pb declareTypes:@[] owner:nil];
      return 0;
    }
    NSString *s = [pb stringForType:NSStringPboardType];
    printf("PLAIN<<%s>>\n", s ? [s UTF8String] : "(nil)");
    NSData *rtf = [pb dataForType:NSRTFPboardType];
    printf("RTFBYTES %lu\n", (unsigned long)[rtf length]);
  }
  return 0;
}
