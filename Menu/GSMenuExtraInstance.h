/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSMenuExtra.h"

@class GSMenuExtraContext;
@class MenuExtraManager;

@interface GSMenuExtraInstance : NSObject

@property (readonly) id<GSMenuExtra> extra;
@property (readonly) NSString *identifier;
@property (readonly) NSString *displayName;
@property (readonly) NSInteger priority;
@property (readonly) GSMenuExtraContext *context;
@property (assign) CGFloat cachedWidth;

/* YES when the extra asked to be in the menu bar from the start.  See
   -enabledByDefault in GSMenuExtra. */
@property (readonly) BOOL enabledByDefault;

- (instancetype)initWithExtra:(id<GSMenuExtra>)extra
                   identifier:(NSString *)identifier
                  displayName:(NSString *)displayName
                     priority:(NSInteger)priority
                     manager:(MenuExtraManager *)manager;

- (BOOL)load;
- (void)unload;
- (BOOL)isIconOnly;
- (BOOL)isHiddenFromMenuBar;

- (NSString *)title;
- (NSMenu *)menu;
- (NSImage *)icon;
- (CGFloat)width;
/* YES when -width is the whole item (the extra implements -totalWidthInMenuBar). */
- (BOOL)statesTotalWidthInMenuBar;
- (void)invalidateWidth;
- (void)tick;
- (void)menuWillOpen;
- (void)menuDidClose;
- (NSInteger)displayPriority;

@end
