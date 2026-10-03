/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface CatalogEntry : NSObject

@property (copy) NSString *name;
@property (copy) NSString *gitURL;
@property (copy) NSString *desc;
@property (copy) NSString *makefilePath;
/* YES when the repository ships git submodules that the build needs; the
   clone then passes --recurse-submodules so third_party trees are present. */
@property (assign) BOOL submodules;
/* Extra arguments passed to gmake, e.g. @[@"OMD_SKIP_TESTS=1"].  Needed for
   aggregates that would otherwise build a test subproject the desktop cannot
   satisfy (Apple's XCTest, for one). */
@property (copy) NSArray *makeArgs;

+ (NSArray *)loadCatalog;
+ (NSArray *)loadCatalogFromPath:(NSString *)catalogPath;
+ (NSString *)localCatalogPath;
+ (NSString *)catalogCachePath;
+ (NSString *)remoteCatalogURLString;

@end
