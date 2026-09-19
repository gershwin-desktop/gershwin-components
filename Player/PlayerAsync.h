/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerAsync_h
#define PlayerAsync_h

#import <Foundation/Foundation.h>

// Background work and main-thread callbacks with NSThread and the run loop.
// Gershwin avoids libdispatch: it has proven unreliable on some of the
// platforms Gershwin runs on.

typedef void (^PlayerBlock)(void);

/// Runs the block on a new thread of its own.
void PlayerRunInBackground(PlayerBlock block);

/// Runs the block on the main thread, also while a modal panel is up or
/// the mouse is tracking.
void PlayerRunOnMainThread(PlayerBlock block);

/// Runs the block on the main thread after the delay.
void PlayerRunOnMainThreadAfter(NSTimeInterval delay, PlayerBlock block);

#endif /* PlayerAsync_h */
