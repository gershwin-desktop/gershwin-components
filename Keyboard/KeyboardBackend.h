/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* How the Keyboard preference pane puts a layout onto the running X server,
 * shared with gershwin-apply-settings so the layout the user chose is put
 * back the same way at every login.  Built as libKeyboardBackend
 * (Libraries/KeyboardBackend) under ARC; objects handed out are autoreleased
 * from the caller's point of view. */
@interface KeyboardBackend : NSObject

/* The setxkbmap binary, or nil when none is installed. */
+ (NSString *)findSetxkbmap;

/* Clears all XKB options first, because setxkbmap -option only ever adds to
 * the options already loaded; an empty variant or options string is left
 * out.  On failure *error holds setxkbmap's stderr. */
+ (BOOL)applyLayout:(NSString *)layout
            variant:(NSString *)variant
            options:(NSString *)options
          setxkbmap:(NSString *)setxkbmapPath
              error:(NSString **)error;

/* Apple ISO keyboards have the key left of 1 and the key left of Z swapped
 * against PC ISO boards, and XKB's applealu_iso model does not remap them. */
+ (BOOL)needsAppleISOKeySwapForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
+ (BOOL)applyAppleISOKeySwap;

/* The layouts XKB knows, read from rules/base.lst: layout code -> human
 * description.  *variantsByLayout (optional) receives layout code -> array of
 * {code, description} dictionaries.  Empty when no base.lst is installed. */
+ (NSDictionary *)availableLayouts:(NSDictionary **)variantsByLayout;

/* The user's saved choice (the KeyboardPreferences domain), which
 * gershwin-apply-settings puts back at login; empty when none was saved. */
+ (NSDictionary *)savedPreferences;

/* Remembers layout and variant for the next login and leaves the other saved
 * keys (options, keyboard type, Apple flag) as the Keyboard pane wrote them. */
+ (void)persistLayout:(NSString *)layout variant:(NSString *)variant;

/* The layouts the user chose to have in the menu bar's Keyboard menu, each a
 * {layout, variant (optional)} dictionary, saved with the other keyboard
 * preferences so the pane and the menu extra agree. */
+ (NSArray *)menuLayouts;
+ (void)setMenuLayouts:(NSArray *)menuLayouts;
+ (BOOL)menuLayouts:(NSArray *)menuLayouts containLayout:(NSString *)layout variant:(NSString *)variant;

/* Switches the Keyboard menu extra on when at least two layouts are chosen for
 * the menu and off when fewer are, in the Menu preferences' saved set, and
 * tells a running Menu.  A menu to switch between one layout is pointless. */
+ (void)syncKeyboardMenuExtraWithMenuLayouts;

/* Posted (distributed) whenever the saved layout or the menu layouts change,
 * so the menu extra in the running Menu follows the preference pane at once. */
extern NSString *const KeyboardBackendPreferencesDidChangeNotification;
+ (void)announcePreferencesChange;

@end
