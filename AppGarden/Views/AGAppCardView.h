/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class AGApp, AGAppCardView, AGInstaller, AGInstallButton;

/*
 * Reported for a press that ends anywhere on the card. A press on the
 * install button never gets here: the button is the hit-tested subview and
 * keeps the click for itself.
 */
@protocol AGAppCardViewDelegate <NSObject>
- (void)appCardViewWasClicked:(AGAppCardView *)cardView;
@end

/*
 * One 200 x 232 tile in the grid: icon, name, two-line summary and the
 * install button.
 *
 * Everything except the button is drawn by this view rather than laid out
 * with subviews. An NSTextField over the card would take part in hit testing
 * and could swallow the press that is meant to open the detail page, and the
 * card redraws on every hover, so measuring text on each frame would show
 * up. The strings are therefore measured and cut to fit once, when the card
 * is bound, and only drawn from then on.
 *
 * The card is flipped, as are AGAppGridView and AGGridLayout's frames, so
 * the y-down arithmetic of the grid continues through the card unchanged.
 */
@interface AGAppCardView : NSView

/*
 * Designated initializer. installer reaches the AGInstallButton this view
 * owns; a nil app afterwards draws an empty pooled card.
 */
- (instancetype)initWithFrame:(NSRect)frame
                    installer:(AGInstaller *)installer NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak) id<AGAppCardViewDelegate> delegate;

/*
 * The bound item. Setting it clears the icon (the grid asks for the new
 * item's icon separately), remeasures the text and rebinds the button.
 * nil is a pooled card between two layout passes; it draws nothing.
 */
@property (nonatomic, strong) AGApp *app;

/* The item's real icon. nil draws AGPlaceholderIcon for the bound app. */
@property (nonatomic, strong) NSImage *icon;

/* Owned by the card; the grid only places it. Exposed so the grid's Space
 * key can press it for the focused card. */
@property (nonatomic, readonly) AGInstallButton *installButton;

/*
 * Keyboard focus, driven by AGAppGridView. A focused card draws the same
 * 2-point accent border as a hovered one, at full alpha instead of half.
 */
@property (nonatomic, getter=isFocused) BOOL focused;

+ (NSSize)cardSize;

/* The application's display name. The card draws its name itself, so this
   is how tools that read the widget tree (DriveUI, the .uitest harness)
   see which card is which. */
- (NSString *)title;

@end
