/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DKList;
@class DKGistClient;

extern NSString * const DKStoreErrorDomain;

/*
 * The single in-memory model of every Docket list, backed by one GitHub
 * gist (one Markdown file per list) and a local cache under the GNUstep
 * Library directory so the app works fully offline between syncs.
 *
 * Sync policy: -pullWithError: always merges (DKLineMerge) rather than
 * overwriting, so a local edit made while offline survives a pull.
 * -pushWithError: first checks whether the gist changed remotely since
 * the last successful pull; if it has, it merges those remote changes in
 * (the same way a pull would) before pushing, so a push can never
 * silently discard someone else's edit.
 */
@interface DKStore : NSObject
{
  NSMutableArray *_lists;
  NSString *_cacheDir;
  NSString *_lastUpdatedAt;
  NSArray *_conflictedListNames;
  DKGistClient *_client; /* rebuilt from DKPreferences before each sync */
}

@property (nonatomic, readonly) NSMutableArray *lists;

/* Filenames (as in DKList's -gistFilename) touched by a merge conflict
 * during the most recent pull or push; empty when the last sync was
 * clean. A conflicted list's notes/tasks contain "<<<<<<< local" /
 * ">>>>>>> remote" markers a person needs to resolve by hand. */
@property (nonatomic, readonly) NSArray *conflictedListNames;

+ (instancetype)sharedStore;

- (DKList *)addListNamed: (NSString *)name;
- (void)removeList: (DKList *)list;

/* Writes one list's current state to the local cache immediately, so an
 * edit survives a crash or a quit even before the next push. */
- (void)saveListLocally: (DKList *)list;

/* Persists the current order of -lists (a drag reorder in the sidebar
 * does not touch any list's own content, only this). */
- (void)persistListOrder;

- (BOOL)pullWithError: (NSError **)error;
- (BOOL)pushWithError: (NSError **)error;

@end
