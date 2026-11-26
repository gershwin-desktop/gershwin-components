/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Turns the linker symbols the Objective-C compilers emit for methods back
   into source notation, so a profile of a GNUstep program reads like the
   code it was built from. */
@interface PRObjCDemangler : NSObject

/* "_i_NSRunLoop_OPENSTEP_performSelector_target_"
   becomes "-[NSRunLoop(OPENSTEP) performSelector:target:]".
   Names that are not method symbols are returned unchanged and set
   *classNameOut to nil. */
+ (NSString *)demangle:(NSString *)rawName
             className:(NSString **)classNameOut;

@end
