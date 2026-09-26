/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWRepository - one entry from Library/Repositories.plist, plus the state
 * Software Update discovers about it during a check (target branch, new
 * commits, build status, local changes). Never hard-code repository data;
 * everything here comes from gershwin-developer or from a live git/GitHub
 * query.
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SWBuildStatus) {
  SWBuildStatusUnknown = 0,
  SWBuildStatusPassed,
  SWBuildStatusFailed,
  SWBuildStatusRunning,
};

@interface SWRepository : NSObject
{
  NSString *_name;
  NSString *_url;
  NSString *_pin;
  BOOL _restartRequired;

  NSString *_currentBranch;
  NSString *_targetBranch;
  BOOL _hasDevBranch;
  NSArray *_commits;            // dictionaries: sha, subject, date, newest first
  SWBuildStatus _buildStatus;
  BOOL _dirty;
  NSUInteger _modifiedFileCount;
  NSString *_unreachableReason; // set when the fetch itself failed
  BOOL _selected;
  BOOL _pinAdvanced;
}

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *pin;             // nil = not pinned
@property (nonatomic) BOOL restartRequired;

@property (nonatomic, copy) NSString *currentBranch;
@property (nonatomic, copy) NSString *targetBranch;
@property (nonatomic) BOOL hasDevBranch;
@property (nonatomic, copy) NSArray *commits;
@property (nonatomic) SWBuildStatus buildStatus;
@property (nonatomic) BOOL dirty;
@property (nonatomic) NSUInteger modifiedFileCount;
@property (nonatomic, copy) NSString *unreachableReason;
@property (nonatomic) BOOL selected;

// Pinned upstream libraries only: YES when the incoming gershwin-developer
// pins this library at a commit different from its current HEAD. The
// Commits column shows the word "new" for these instead of a count; there
// is no commit list to show (per spec, "pin" is never surfaced in the UI).
@property (nonatomic) BOOL pinAdvanced;

@property (nonatomic, readonly) BOOL isPinned;
@property (nonatomic, readonly) NSUInteger commitCount;

// Whether there is anything to install for this repository: new commits for
// an ordinary repo, or an advanced pin for an upstream library. Only
// repositories with something to install are listed in the main window.
@property (nonatomic, readonly) BOOL hasUpdate;

// Whether the repository can be checked/selected at all right now: not
// blocked by a failed fetch, since a repository Software Update never even
// reached has nothing to show or offer.
@property (nonatomic, readonly) BOOL isReachable;

- (instancetype)initWithPlistEntry:(NSDictionary *)entry;

@end
