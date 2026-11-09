/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class AGApp, AGInstaller;

typedef NS_ENUM(NSInteger, AGInstallButtonStyle) {
    /* 80 x 22, 11 pt bold. Fits "Open Page" with room to spare. */
    AGInstallButtonStyleCard = 0,
    /* 120 x 28, 13 pt bold, for the detail page header. */
    AGInstallButtonStyleDetail
};

/*
 * The one install control, used on the cards (small) and on the detail page
 * (large). It is an NSView rather than an NSButton because four of its seven
 * states are not buttons at all: a progress bar, a grey placeholder and two
 * disabled reads that must still show their title.
 *
 * This view is the one place in AppGarden that talks to AGInstaller. It is
 * given both the AGApp and the AGInstaller, starts and cancels installs,
 * shows an installed file in the file manager, opens the download page and
 * reports a failed install in an alert, so a card or the detail page only
 * has to place it. It keeps
 * itself correct by observing AGInstaller's two notifications for its own
 * app name, which is what lets a card scroll out of view and come back in
 * step without the controller doing anything.
 */
@interface AGInstallButton : NSView

/*
 * Designated initializer. installer must not be nil; app is set afterwards
 * through the property, and a nil app renders the Unavailable state until one
 * arrives (a pooled card has no app bound between two layout passes).
 */
- (instancetype)initWithFrame:(NSRect)frame
                        style:(AGInstallButtonStyle)style
                    installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, strong) AGApp *app;

/* The size each style expects; controllers size the view with it instead of
 * repeating the two numbers. */
+ (NSSize)sizeForStyle:(AGInstallButtonStyle)style;

/*
 * Recomputes the state from the installer and redraws. Called automatically
 * on a relevant notification and when app changes; a controller that
 * installs or removes something synchronously may call it too.
 */
- (void)reloadState;

/*
 * Runs whatever the current state's click does: start the install, cancel a
 * running one, show an installed file in the file manager, open the download
 * page, show the failure alert. The grid's Space key calls this for the
 * focused card.
 */
- (void)performClick;

@end
