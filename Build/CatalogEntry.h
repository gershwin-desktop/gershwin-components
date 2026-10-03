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

+ (NSArray *)loadCatalog;
+ (NSArray *)loadCatalogFromPath:(NSString *)catalogPath;
+ (NSString *)localCatalogPath;
+ (NSString *)catalogCachePath;
+ (NSString *)remoteCatalogURLString;

@end
