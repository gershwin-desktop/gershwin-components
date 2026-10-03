/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef PlayerMenu_h
#define PlayerMenu_h

#import <AppKit/AppKit.h>

/// Tag of the separator after which the Radio menu lists the stations.
enum { PlayerMenuStationListTag = 9999 };

/**
 * Builds Player's main menu.  Player commands go to the given target;
 * window and text commands go along the responder chain.  Titles, check
 * marks and enabled state are kept up to date by the target's
 * -validateMenuItem:.
 */
@interface PlayerMenu : NSObject
+ (NSMenu *)mainMenuWithTarget:(id)target;
@end

#endif /* PlayerMenu_h */
