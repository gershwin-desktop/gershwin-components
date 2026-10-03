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

// /Developer is meant to be shared between users, so its checkouts regularly
// belong to somebody other than whoever runs Software Update - and git either
// refuses to work in a repository it does not own at all ("detected dubious
// ownership") or cannot write the results of a fetch into it. Such a
// repository is run through sudo instead, with an explicit safe.directory
// exemption for that one path, since root does not own it either.

// YES when git could not work in a repository at path as the current user:
// somebody else owns it, or this user may not write to it - so it has to be
// run with elevated privileges. "May not write" covers the whole object
// database, not just the worktree and .git: a loose object is written into
// .git/objects/<xx>, so one <xx> directory left behind by a git that ran as
// root makes every unprivileged fetch fail with "insufficient permission for
// adding an object to repository database", and the remote-tracking ref then
// never moves, which reads as "no updates" on a repository that is behind.
// NO when this process is already root, when the repository is ours to use,
// or when it does not exist (git then reports the real problem itself).
+ (BOOL)needsElevationForPath:(NSString *)path;

// Asks sudo - once, before the first git runs - for the permission every
// elevated call in this process runs under, so the user is prompted at most
// once per check instead of once per repository, and never in parallel with
// itself. Returns YES when git may run (none of the paths needs elevation,
// or it was granted); otherwise *outReason, if given, receives the message
// to show the user. Never prompts when no path needs elevation. The command
// and its output go to logHandler, like every git invocation's do.
+ (BOOL)prepareElevationForPaths:(NSArray<NSString *> *)paths
                      logHandler:(SWGitLogLine)logHandler
                          reason:(NSString **)outReason;

// Runs `git -C <path> fetch --prune origin`. Returns NO (and logs stderr) if
// the fetch failed - the remote could not be reached, or git was not allowed
// to write the objects - in which case *outError, if given, receives git's
// own first line of complaint so the failure can be reported as what it is
// rather than as "no updates".
- (BOOL)fetchPruneOrigin:(NSString **)outError;

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
// fast-forward was not possible (local commits diverged) - or because
// -untrackedPathsBlockingFastForwardTo: said a file is in the way, which is a
// different problem and has to be cleared first.
- (BOOL)switchAndFastForwardTo:(NSString *)branch;

// The files in the working tree that a fast-forward to <target> would have to
// create, and that therefore make `git merge --ff-only` abort with "the
// following untracked working tree files would be overwritten by merge".
//
// Paths the incoming commits add, as git diff reports them (adds only, with
// renames broken into a delete and an add, so a moved file's new name counts),
// narrowed to the ones that exist on disk. A path HEAD already knows about is
// tracked, so it is never in this list; a path that exists and is not tracked
// is one git will refuse to overwrite, whatever it is - a user's new source
// file, a build product that .gitignore does not cover, a whole directory.
//
// This matters because untracked files are never stashed: the tree looks clean
// to -modifiedFileCount, nothing is moved out of the way, and the refusal was
// reported to the user as a divergence on a repository git itself says can be
// fast-forwarded. Empty when there is nothing in the way.
- (NSArray<NSString *> *)untrackedPathsBlockingFastForwardTo:(NSString *)target;

// Absolute path of the directory displaced files are moved into
// (see -setAsideUntrackedPaths:failure:), and where one of them can be found
// afterwards. Inside .git rather than beside the file, so nothing in the
// working tree can mistake it for a checkout, no build sees it, and neither
// `git checkout -- .`, `git reset --merge` nor a `git clean` of the worktree
// can reach it.
- (NSString *)setAsideDirectoryPath;
- (NSString *)setAsidePathForRelativePath:(NSString *)relativePath;

// Moves each of <paths> (relative to the repository root, as -untrackedPaths-
// BlockingFastForwardTo: returns them) out of the working tree so the
// fast-forward can write them, keeping the directory structure underneath
// .git/software-update-aside. Never deletes and never overwrites: a displaced
// file is the user's only copy of itself, so an existing set-aside copy at the
// same path is a refusal, not something to replace. Returns NO on the first
// path that could not be moved, with *outFailure naming it - and whatever
// already moved stays moved, so the caller must reconcile rather than assume
// the working tree is as it was.
- (BOOL)setAsideUntrackedPaths:(NSArray<NSString *> *)paths
                      failure:(NSString **)outFailure;

// After the fast-forward: a set-aside copy of one of <paths> that is byte for
// byte what the checkout produced is redundant - the file had reached the
// repository by some route other than git - and is removed, because left behind
// it would clutter every later run. A copy that differs is the user's own work
// and stays where it is; its paths are returned so it can be reported. Anything
// that is not a plain file (a directory the update would create, a symbolic
// link) is kept and reported rather than compared: a tree is not a file, and
// deciding it equivalent would mean walking both sides.
//
// <paths> are the ones -setAsideUntrackedPaths:failure: was given, not whatever
// the directory happens to hold: only the files this run displaced are
// reconciled, never one left behind by an earlier run that this knows nothing
// about. It has side effects, so it is not a getter. Calling it again reports
// a kept copy again - it is still the user's file and still has to be named -
// but never resurrects one that was removed.
- (NSArray<NSString *> *)reconcileSetAsidePaths:(NSArray<NSString *> *)paths;

// Moves the set-aside copies of <paths> back to where they came from, for when
// the update is abandoned and the working tree has to be exactly as it was.
// Never overwrites: a path the working tree already has is left to the working
// tree, and the copy stays put. Returns the paths that could not go back, so
// the caller can say where the user's file still is.
- (NSArray<NSString *> *)restoreSetAsidePaths:(NSArray<NSString *> *)paths;

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
