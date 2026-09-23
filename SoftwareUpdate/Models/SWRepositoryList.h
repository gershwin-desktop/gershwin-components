/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWRepositoryList - reads gershwin-developer's Library/Repositories.csv,
 * the single source of truth for which repositories exist, their order,
 * upstream pins and restart requirement. Never hard-code any of that here.
 *
 * CSV rather than a plist so checkout.sh (a POSIX shell script that must run
 * before GNUstep exists) can parse it with plain awk; no field here (a name,
 * URL or sha) ever contains a comma, so a bare split is enough on both sides.
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"

extern NSString *const SWRepositoryListErrorDomain;

typedef NS_ENUM(NSInteger, SWRepositoryListError) {
  SWRepositoryListErrorFileNotFound = 1,
  SWRepositoryListErrorMalformed,
};

@interface SWRepositoryList : NSObject

// Repositories.csv under a gershwin-developer checkout, e.g.
// "/Developer/Library/Repositories.csv".
+ (NSArray<SWRepository *> *)repositoriesFromCSVAtPath:(NSString *)path
                                                  error:(NSError **)error;

// Same, but parses already-read CSV data (e.g. the content of
// origin/<branch>:Library/Repositories.csv via `git show`, for checking
// with pins that have not been pulled locally yet).
+ (NSArray<SWRepository *> *)repositoriesFromCSVData:(NSData *)data
                                                error:(NSError **)error;

@end
