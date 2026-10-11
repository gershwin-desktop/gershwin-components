/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* :0 is the real screen of a desktop; nested servers start at :1. */
extern const NSInteger XLMinimumDisplayNumber;
extern const NSInteger XLMaximumDisplayNumber;
extern const NSInteger XLMinimumDimension;
extern const NSInteger XLMaximumDimension;
extern const NSInteger XLMaximumScreenCount;

/* The decisions made before Xephyr is started, kept free of AppKit so they
 * can be tested headless. */
@interface XLXephyr : NSObject

/* Lowest display number that has neither a socket in socketDirectory nor
 * a live lock file in lockDirectory, or -1 when all are taken. */
+ (NSInteger)firstFreeDisplayNumberWithSocketDirectory:(NSString *)socketDirectory
                                         lockDirectory:(NSString *)lockDirectory;
+ (NSInteger)firstFreeDisplayNumber;

/* Full path of the first executable Xephyr in the colon separated searchPath,
 * nil when there is none. */
+ (NSString *)xephyrPathInSearchPath:(NSString *)searchPath;
+ (NSString *)xephyrPath;

/* A whole number between 1 and XLMaximumDimension, 0 for anything else. */
+ (NSInteger)dimensionFromString:(NSString *)string;

/* Localized description of what is wrong with the request, nil when fine. */
+ (NSString *)validationErrorForWidth:(NSInteger)width
                               height:(NSInteger)height
                          screenCount:(NSInteger)screenCount;

+ (NSString *)displayStringForNumber:(NSInteger)number;
+ (NSArray *)argumentsForDisplayNumber:(NSInteger)number
                                 width:(NSInteger)width
                                height:(NSInteger)height
                           screenCount:(NSInteger)screenCount;

/* Environment for a client of the nested display. */
+ (NSDictionary *)environmentForDisplayNumber:(NSInteger)number
                              baseEnvironment:(NSDictionary *)base;

/* Path of the X11 socket of a display in the standard socket directory. */
+ (NSString *)socketPathForDisplayNumber:(NSInteger)number;

@end
