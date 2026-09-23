/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWGitTool - thin wrapper around the git plumbing commands Software Update
 * needs, run off the main thread. Every invocation is also handed to a
 * logger block so the Log window can show "$ git ..." plus its output,
 * per the spec: progress windows never show raw command output, only the
 * Log window does.
 */

#import <Foundation/Foundation.h>

// One commit, newest first, as produced by -logMessagesFrom:to:in:.
@interface SWGitCommit : NSObject
@property (nonatomic, copy) NSString *sha;
@property (nonatomic, copy) NSString *subject;
@property (nonatomic, copy) NSString *date;
@end

// Invoked with the full command line before it runs, and with each line of
// combined stdout+stderr as it arrives, in arrival order - matching what the
// Log window records ("$" for a user-level git invocation).
typedef void (^SWGitLogLine)(NSString *line);

@interface SWGitTool : NSObject

@property (nonatomic, copy) SWGitLogLine logHandler;

- (instancetype)initWithRepositoryPath:(NSString *)path;

// Runs `git -C <path> fetch --prune origin`. Returns NO (and logs stderr) if
// the remote could not be reached at all.
- (BOOL)fetchPruneOrigin;

// `git -C <path> rev-parse --abbrev-ref HEAD`, or nil if detached/unknown.
- (NSString *)currentBranch;

// `git -C <path> ls-remote --exit-code --heads origin <branch>`.
- (BOOL)remoteHasBranch:(NSString *)branch;

// `git -C <path> rev-list --count HEAD..origin/<target>`.
- (NSUInteger)commitCountBehindTarget:(NSString *)target;

// `git -C <path> log --format=%h%x09%s%x09%as HEAD..origin/<target>`, newest first.
- (NSArray<SWGitCommit *> *)commitsBehindTarget:(NSString *)target;

// `git -C <path> status --porcelain --untracked-files=no`; count of modified
// files (dirty working tree, excluding untracked files - those are never
// stashed).
- (NSUInteger)modifiedFileCount;

// `git -C <path> stash push -m <message>`. Returns NO if there was nothing
// to stash or the stash failed (check -modifiedFileCount first).
- (BOOL)stashPushWithMessage:(NSString *)message;

// `git -C <path> stash pop`. Returns NO on conflict; conflicted paths are
// reported by -conflictedPaths (still valid after a failed pop).
- (BOOL)stashPop;
- (NSArray<NSString *> *)conflictedPaths;
- (BOOL)resetMerge;

// `git -C <path> checkout -- .` - discards all uncommitted changes to
// tracked files (used to undo a patch.sh application before re-applying the
// user's own stash, so the two never collide).
- (BOOL)discardTrackedChanges;

// `git -C <path> switch <branch>` (creating a tracking branch if needed),
// then `git -C <path> merge --ff-only origin/<branch>`. Returns NO if the
// fast-forward was not possible (local commits diverged).
- (BOOL)switchAndFastForwardTo:(NSString *)branch;

// `git -C <path> checkout <ref>` - used both to pin an upstream library and
// to roll a repository back to the HEAD recorded before the update.
- (BOOL)checkoutRef:(NSString *)ref;

// `git -C <path> rev-parse HEAD` - the commit to remember before touching
// the repository, so a failed update can roll back to it.
- (NSString *)headCommit;

// origin's default branch (e.g. "main"), from `git -C <path> symbolic-ref
// --short refs/remotes/origin/HEAD`, refreshing it once via `git remote
// set-head origin -a` if it was never recorded locally. Nil if it cannot be
// determined at all.
- (NSString *)defaultBranch;

// `git -C <path> show <ref>:<file>` - used to read a file's content as it
// will be after an update (e.g. gershwin-developer's incoming
// Repositories.plist), without checking it out first.
- (NSData *)showFileAtRef:(NSString *)ref path:(NSString *)path;

// `git -C <path> rev-parse <ref>^{commit}` - resolves an abbreviated sha (or
// any ref) to the full commit sha it names, or nil if the object is not
// present locally (e.g. a pin that has not been fetched yet).
- (NSString *)fullShaForRef:(NSString *)ref;

@end
