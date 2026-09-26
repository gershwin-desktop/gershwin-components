/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWProgressWindowController - spec screens 4/5, one shared window for
 * "Install prerequisites" and "Update each repository". Progressive
 * disclosure: headline, determinate progress bar, one status line, Details
 * (collapsed by default) and Stop. Details reveals one box: the three run
 * phases with done/running/pending marks, and the running phase's items
 * (missing packages, or repositories) indented beneath it.
 */

#import <AppKit/AppKit.h>
#import "SWProgressPhase.h"

@class SWProgressWindowController;

@protocol SWProgressWindowControllerDelegate <NSObject>
- (void)progressWindowControllerDidClickStop:(SWProgressWindowController *)controller;
@end

@interface SWProgressWindowController : NSWindowController

@property (nonatomic, weak) id<SWProgressWindowControllerDelegate> delegate;

// Phases in run order, e.g. [developer?, prereqs, repos]. Called once before
// the run starts; "repos" phase items can be filled in immediately since
// the selected repository list is already known to the GUI.
- (void)setPhases:(NSArray<SWProgressPhase *> *)phases;

- (SWProgressPhase *)phaseWithIdentifier:(NSString *)identifier;

// Marks the named phase running (and any earlier phase done), refreshes the
// headline/status line, and redraws the phases box if Details is open.
- (void)beginPhaseWithIdentifier:(NSString *)identifier headline:(NSString *)headline;
- (void)finishPhaseWithIdentifier:(NSString *)identifier;

// Marks items before index done and the item at index running (with
// trailingText, e.g. the current step verb), within the named phase.
- (void)beginItemAtIndex:(NSUInteger)index
       inPhaseWithIdentifier:(NSString *)identifier
                trailingText:(NSString *)trailingText;

- (void)setStatusText:(NSString *)text;
- (void)setOverallProgress:(float)fraction; // 0.0-1.0

@end
