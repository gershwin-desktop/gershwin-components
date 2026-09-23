/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SWSelectionRules - which repositories the main window checks by default,
 * and why a blocked one cannot be selected. Pure logic, no I/O: it only
 * looks at fields SWUpdatePlan has already filled in on each repository.
 */

#import <Foundation/Foundation.h>
#import "SWRepository.h"

@interface SWSelectionRules : NSObject

// Sets -selected on every repository per the rule: build passed or unknown
// -> selected; build failed or still running -> not selected (the row stays
// visible and choosable for its details, just not for the update itself).
// An unreachable repository (fetch failed) is never selected.
+ (void)applyDefaultSelectionToRepositories:(NSArray<SWRepository *> *)repositories;

// nil when the repository can be selected; otherwise the reason text that
// follows its name in the Repository cell, e.g.
// "Build failed on server, please retry later".
+ (NSString *)blockedReasonForRepository:(SWRepository *)repository;

@end
