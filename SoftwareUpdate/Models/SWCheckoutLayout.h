/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWCheckoutLayout - where Software Update finds each repository and
 * gershwin-developer's own files (Repositories.csv, the install script, the
 * patch sets, the OS package lists).
 *
 * /Developer is itself the gershwin-developer working copy: the user and
 * every script run from it. Repositories.csv also names gershwin-developer,
 * so checkout.sh used to clone a second copy into Library/Sources. Fetching
 * that copy while reading the package lists and scripts from /Developer meant
 * the files that tell the build what it needs never moved. So
 * gershwin-developer always resolves to the developer directory here, and the
 * second copy is never looked at.
 */

#import <Foundation/Foundation.h>

extern NSString *const SWDeveloperRepositoryName;

@interface SWCheckoutLayout : NSObject

// The installed system's layout: /Developer and /Developer/Library/Sources.
+ (instancetype)systemLayout;

// Both injectable so tests can place the developer checkout anywhere.
- (instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory
                          sourcesDirectory:(NSString *)sourcesDirectory;

@property (nonatomic, readonly, copy) NSString *developerDirectory;
@property (nonatomic, readonly, copy) NSString *sourcesDirectory;

@property (nonatomic, readonly) NSString *repositoriesCSVPath;
@property (nonatomic, readonly) NSString *scriptsDirectory;
@property (nonatomic, readonly) NSString *installScriptPath;
@property (nonatomic, readonly) NSString *patchesDirectory;
@property (nonatomic, readonly) NSString *osSupportDirectory;

// The package list for one OS, relative to the developer checkout, the form
// "git show <ref>:<path>" needs to read an incoming version of it.
+ (NSString *)packageListPathForOSIdentifier:(NSString *)osIdentifier;

// The working copy of a repository named in Repositories.csv.
- (NSString *)pathForRepositoryNamed:(NSString *)name;

@end
