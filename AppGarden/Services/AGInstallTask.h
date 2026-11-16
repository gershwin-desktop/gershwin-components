/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class AGApp;

typedef NS_ENUM(NSInteger, AGInstallTaskState) {
    AGInstallTaskStateWaiting = 0,
    AGInstallTaskStateDownloading,
    AGInstallTaskStateDone,
    AGInstallTaskStateFailed,
    AGInstallTaskStateCancelled
};

/*
 * One run of an install, from the click on Get until it ends.
 *
 * The readwrite properties sit in an extension rather than in the public
 * interface because AGInstaller is the only writer and there is no second
 * writer to protect against; putting the extension in this header keeps
 * AGInstallTask.m free of a second, private header while still telling every
 * reader that it must not assign to them.
 */
@interface AGInstallTask : NSObject

@property (nonatomic, readonly, strong) AGApp *app;
@property (nonatomic, readonly) AGInstallTaskState state;

/* 0.0 .. 1.0, or -1 while the current phase has no measurable size. */
@property (nonatomic, readonly) float progress;

/* Short, user-facing phase text: "Resolving release...", "Downloading 34 MB...". */
@property (nonatomic, readonly, copy) NSString *message;

/* Non-nil only in state Failed. Carries a human-readable
 * NSLocalizedDescriptionKey; AGInstallTask is also where a bare GitHub rate
 * limit message is rewritten into something the user can act on. */
@property (nonatomic, readonly, strong) NSError *error;

- (instancetype)initWithApp:(AGApp *)app NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface AGInstallTask ()
@property (nonatomic, readwrite, strong) AGApp *app;
@property (nonatomic, readwrite) AGInstallTaskState state;
@property (nonatomic, readwrite) float progress;
@property (nonatomic, readwrite, copy) NSString *message;
@property (nonatomic, readwrite, strong) NSError *error;
@end
