/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "PRRecorder.h"

/* Picks the tool that can measure what the user asked for on the system
   this is running on. */
@interface PRRecorderFactory : NSObject

+ (Class)recorderClassForMode:(PRProfileMode)mode;
/* nil when the mode can be recorded, otherwise why it cannot. */
+ (NSString *)problemForMode:(PRProfileMode)mode;
+ (NSString *)toolNameForMode:(PRProfileMode)mode;

@end
