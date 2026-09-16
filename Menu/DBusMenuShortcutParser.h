/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <X11/Xlib.h>

@interface DBusMenuShortcutParser : NSObject

// Parse shortcut array from DBus menu properties
+ (NSString *)parseShortcutArray:(NSArray *)shortcutArray;

// Parse key combination string into key and modifiers
+ (NSDictionary *)parseKeyCombo:(NSString *)keyCombo;

// Normalize key names for NSMenuItem
+ (NSString *)normalizeKeyName:(NSString *)keyName;

// Undo gtk_accelerator_get_label()'s translation of a modifier or key name
+ (NSString *)canonicalGTKKeyName:(NSString *)name;

// YES for F1 - F35, the only key equivalents worth grabbing without modifiers
+ (BOOL)isFunctionKeyEquivalent:(NSString *)keyEquivalent;

// Whether this key equivalent may be grabbed as a global X11 shortcut
+ (BOOL)shouldRegisterGlobalShortcutForKey:(NSString *)keyEquivalent
                                 modifiers:(NSUInteger)modifierMask;

// Resolve a key equivalent back to the X11 keysym the global grab needs
+ (KeySym)keysymForKeyEquivalent:(NSString *)keyEquivalent;

// Convert modifier mask to string representation
+ (NSString *)modifierMaskToString:(NSUInteger)modifierMask;

// Test method for shortcut parsing (exposed for testing)
+ (NSDictionary *)testParseKeyCombo:(NSString *)keyCombo;

@end
