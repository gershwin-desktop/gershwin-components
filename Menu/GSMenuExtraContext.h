/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class MenuExtraManager;

@interface GSMenuExtraContext : NSObject

@property (nonatomic, weak) MenuExtraManager *manager;
@property (nonatomic, copy) NSString *identifier;

- (instancetype)initWithManager:(MenuExtraManager *)manager
                     identifier:(NSString *)identifier;

- (void)invalidatePresentation;

/* Tells the manager that the width measured for this extra is stale, so that
   the next time the bar is laid out it is measured again.  An extra that
   changes shape - appearing, disappearing, growing a title - calls this
   alongside -invalidatePresentation; one that does not need never does. */
- (void)invalidateWidth;

@end
