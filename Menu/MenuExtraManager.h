/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GSMenuExtraInstance;
@class MenuExtraManager;

/* The gap between the extras and the end of the bar.
 *
 * One number, used by both the manager (which places the extras) and the
 * controller (which lays the app titles out in what is left), because the two
 * have to agree: a margin that differed between them would show up as the
 * titles and the extras not lining up. */
extern const CGFloat GSExtrasEdgeMargin;

@protocol MenuExtraConfigProtocol
- (BOOL)updateEnabledExtras:(NSArray *)identifiers;
@end

@protocol MenuExtraManagerDelegate <NSObject>
/* The extras changed width or number, so the rest of the bar - the app
   titles, and whatever else shares the bar - has to be laid out again
   against the width the extras now take. */
- (void)menuExtraManagerNeedsLayout:(MenuExtraManager *)manager;
@end

@interface MenuExtraManager : NSObject <MenuExtraConfigProtocol>

@property (nonatomic, strong) NSMutableArray<GSMenuExtraInstance *> *menuExtras;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, assign) CGFloat screenWidth;
@property (nonatomic, assign) CGFloat menuBarHeight;

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height;

- (void)loadMenuExtras;
- (NSView *)createExtrasMenuView;
- (CGFloat)extrasMenuWidth;
- (void)startUpdateTimers;
- (void)stopUpdateTimers;
- (void)unloadAllMenuExtras;

- (void)refreshExtraWithIdentifier:(NSString *)identifier;

/* Told when the extras need the rest of the bar laid out again.  Weak, and
   the manager works without one - it then only resizes itself, which is
   enough while the bar is being built. */
@property (nonatomic, weak) id<MenuExtraManagerDelegate> layoutDelegate;

/* Drops the width measured for one extra, so the next layout asks it again.
   For an extra whose width follows its state - an icon that appears and
   disappears with what is playing - and for nothing else. */
- (void)invalidateWidthForExtraWithIdentifier:(NSString *)identifier;
- (void)savePreferences;
- (void)reloadEnabledFromDefaults;
- (NSArray<GSMenuExtraInstance *> *)allMenuExtras;

- (void)showPreferencesPanel;

/* ── Menu bar layout (extras collapse) ─────────────────────────── */

/* Natural (unfolded) width of each currently-enabled extra, in the order
   they collapse in when the bar runs out of room: least important (nearest
   the app's own titles) first.  Feed this to
   +[MenuBarLayout layoutForBarWidth:...] to decide how many fit. */
- (NSArray<NSNumber *> *)naturalExtraWidthsLeastImportantFirst;

/* Fold the leading `count` extras (in the order above) behind a single
   overflow item at the front of the extras cluster; the rest keep showing
   directly.  0 restores every extra to normal display.  Reuses the same
   NSMenuItem objects the extras were already built with, so anything that
   updates an extra's title/icon by identifier (the periodic tick) keeps
   working regardless of fold state.  Safe to call every time the bar is
   laid out; a no-op when the requested count is already applied. */
- (void)setCollapsedExtraCount:(NSUInteger)count;

@end
