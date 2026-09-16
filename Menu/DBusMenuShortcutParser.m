/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DBusMenuShortcutParser.h"
#import <X11/Xlib.h>
#import <X11/keysym.h>
#include <libintl.h>
#include <locale.h>

/* Keysym ranges used to classify numeric shortcut values sent by
 * GTK / Canonical AppMenu clients.  GDK key values (which are what
 * most toolkits send over D-Bus) are nearly identical to the
 * corresponding X11 keysyms in the ASCII / Latin-1 range. */
#define XK_MODIFIER_MIN   0xFFE0u
#define XK_MODIFIER_MAX   0xFFFFu

/* Mapping table: X11 keysym → canonical modifier name.  Entries are
 * grouped by modifier so we can binary-search or simply linear-scan;
 * the table is small so a linear scan is fine. */
typedef struct {
    unsigned int  keysym;
    const char   *modName;   /* e.g. "ctrl", "shift", "alt", "cmd" */
} KeysymModEntry;

static KeysymModEntry const modifier_map[] = {
    /* Control */
    { XK_Control_L,    "ctrl" },
    { XK_Control_R,    "ctrl" },
    /* Shift */
    { XK_Shift_L,      "shift" },
    { XK_Shift_R,      "shift" },
    /* Alt */
    { XK_Alt_L,        "alt" },
    { XK_Alt_R,        "alt" },
    { XK_Meta_L,       "alt" },
    { XK_Meta_R,       "alt" },
    /* Super / Command */
    { XK_Super_L,      "cmd" },
    { XK_Super_R,      "cmd" },
    { XK_Hyper_L,      "cmd" },
    { XK_Hyper_R,      "cmd" },
};

#define NUM_MODIFIER_MAP (sizeof(modifier_map) / sizeof(modifier_map[0]))


/* The English names GTK renders accelerator labels from.  Every one of them
 * is translated with the "keyboard label" message context in GTK's own
 * catalogue, which is how "Strg+Umschalt+Entf" reaches us. */
static char const * const gtk_keyboard_labels[] = {
    "Ctrl", "Shift", "Alt", "Super", "Meta", "Hyper",
    "Space", "Backslash", "Backspace", "Delete", "Return", "Enter", "Esc",
    "Home", "End", "Page_Up", "Page_Down", "Insert", "Tab",
    "Up", "Down", "Left", "Right",
    "KP_Space", "KP_Tab", "KP_Enter", "KP_Home", "KP_Left", "KP_Up",
    "KP_Right", "KP_Down", "KP_Page_Up", "KP_Page_Down", "KP_End",
    "KP_Begin", "KP_Insert", "KP_Delete",
};

#define NUM_GTK_KEYBOARD_LABELS \
    (sizeof(gtk_keyboard_labels) / sizeof(gtk_keyboard_labels[0]))

/* GTK's message catalogues, newest first: an app may be built against any of
 * them and they all translate the same message context. */
static char const * const gtk_text_domains[] = { "gtk40", "gtk30", "gtk20" };

#define NUM_GTK_TEXT_DOMAINS \
    (sizeof(gtk_text_domains) / sizeof(gtk_text_domains[0]))

@implementation DBusMenuShortcutParser

+ (NSString *)parseShortcutArray:(NSArray *)shortcutArray
{
    // Convert DBus shortcut array to string format
    // DBus shortcuts are typically nested arrays like ((Control, t)) or ((Control, Shift, x))
    if (![shortcutArray isKindOfClass:[NSArray class]] || [shortcutArray count] == 0) {
        NSDebugLog(@"DBusMenuShortcutParser: Invalid shortcut array - not array or empty");
        return nil;
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Parsing shortcut array: %@", shortcutArray);
    
    // The shortcut array might be nested - check if first element is an array
    NSArray *actualShortcut = shortcutArray;
    if ([shortcutArray count] > 0 && [[shortcutArray objectAtIndex:0] isKindOfClass:[NSArray class]]) {
        // Take the first nested array - this is the actual shortcut
        actualShortcut = [shortcutArray objectAtIndex:0];
        NSDebugLog(@"DBusMenuShortcutParser: Found nested shortcut array: %@", actualShortcut);
    }
    
    NSMutableArray *components = [NSMutableArray array];
    NSString *key = nil;
    
    for (id item in actualShortcut) {
        if ([item isKindOfClass:[NSString class]]) {
            NSString *component = (NSString *)item;
            NSDebugLog(@"DBusMenuShortcutParser: Processing shortcut component: '%@'", component);
            
            // Check if it's a modifier - map modifiers (case-insensitive)
            NSString *lowerComponent = [component lowercaseString];
            if ([lowerComponent isEqualToString:@"control_l"] || [lowerComponent isEqualToString:@"control_r"] || 
                [lowerComponent isEqualToString:@"control"] || [lowerComponent isEqualToString:@"ctrl"]) {
                [components addObject:@"ctrl"]; // Control key
                NSDebugLog(@"DBusMenuShortcutParser: Added Control modifier");
            } else if ([lowerComponent isEqualToString:@"shift_l"] || [lowerComponent isEqualToString:@"shift_r"] || 
                       [lowerComponent isEqualToString:@"shift"]) {
                [components addObject:@"shift"];
                NSDebugLog(@"DBusMenuShortcutParser: Added Shift modifier");
            } else if ([lowerComponent isEqualToString:@"alt_l"] || [lowerComponent isEqualToString:@"alt_r"] || 
                       [lowerComponent isEqualToString:@"alt"]) {
                [components addObject:@"alt"];
                NSDebugLog(@"DBusMenuShortcutParser: Added Alt modifier");
            } else if ([lowerComponent isEqualToString:@"meta_l"] || [lowerComponent isEqualToString:@"meta_r"] || 
                       [lowerComponent isEqualToString:@"super_l"] || [lowerComponent isEqualToString:@"super_r"] ||
                       [lowerComponent isEqualToString:@"hyper_l"] || [lowerComponent isEqualToString:@"hyper_r"] ||
                       [lowerComponent isEqualToString:@"meta"] || [lowerComponent isEqualToString:@"super"] ||
                       [lowerComponent isEqualToString:@"hyper"] || [lowerComponent isEqualToString:@"cmd"] ||
                       [lowerComponent isEqualToString:@"command"]) {
                [components addObject:@"cmd"]; // Command/Super key
                NSDebugLog(@"DBusMenuShortcutParser: Added Command modifier");
            } else {
                // This should be the key
                key = [self normalizeKeyName:component];
                NSDebugLog(@"DBusMenuShortcutParser: Found key: '%@' -> '%@'", component, key);
            }
        } else if ([item isKindOfClass:[NSNumber class]]) {
            // Handle numeric keysyms (common in GTK/Chrome apps)
            unsigned int keysymVal = [item unsignedIntValue];
            NSDebugLog(@"DBusMenuShortcutParser: Processing numeric shortcut component: %u", keysymVal);
            
            // 1. Check if it's a modifier keysym (XF86/GDK range)
            BOOL foundModifier = NO;
            for (NSUInteger i = 0; i < NUM_MODIFIER_MAP; i++) {
                if (modifier_map[i].keysym == keysymVal) {
                    NSString *modName = [NSString stringWithUTF8String:modifier_map[i].modName];
                    [components addObject:modName];
                    NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u matched modifier '%@'", 
                          keysymVal, modName);
                    foundModifier = YES;
                    break;
                }
            }
            if (foundModifier) continue;
            
            // 2. Check for printable ASCII / Latin-1 range (0x20-0xFF)
            if (keysymVal >= 0x20 && keysymVal <= 0xFF) {
                // Use the Unicode/ASCII character directly.
                // Note: X11 keysyms in this range equal the corresponding
                // ASCII / Latin-1 codepoint for most practical purposes.
                unichar c = (unichar)(keysymVal & 0x7F);
                if (c >= 0x20 && c <= 0x7E) {
                    key = [NSString stringWithCharacters:&c length:1];
                    NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u -> ASCII '%@'", keysymVal, key);
                    continue;
                }
            }
            
            // 3. Try X11 Keysym-to-string conversion
            char *ksName = XKeysymToString((KeySym)keysymVal);
            if (ksName) {
                NSString *ksStr = [NSString stringWithUTF8String:ksName];
                NSDebugLog(@"DBusMenuShortcutParser: Numeric value %u -> keysym name '%@'", keysymVal, ksStr);
                
                // Check keysym name for modifiers (case-insensitive)
                NSString *lowerKs = [ksStr lowercaseString];
                if ([lowerKs hasSuffix:@"_l"] || [lowerKs hasSuffix:@"_r"]) {
                    // Could be a left/right variant of a modifier
                    NSString *base = [lowerKs substringToIndex:[lowerKs length] - 2];
                    if ([base isEqualToString:@"control"] || [base isEqualToString:@"ctrl"]) {
                        [components addObject:@"ctrl"];
                        continue;
                    } else if ([base isEqualToString:@"shift"]) {
                        [components addObject:@"shift"];
                        continue;
                    } else if ([base isEqualToString:@"alt"]) {
                        [components addObject:@"alt"];
                        continue;
                    } else if ([base isEqualToString:@"meta"] || [base isEqualToString:@"super"] || 
                               [base isEqualToString:@"hyper"] || [base isEqualToString:@"cmd"]) {
                        [components addObject:@"cmd"];
                        continue;
                    }
                }
                
                // Use the keysym name as the key
                key = [self normalizeKeyName:ksStr];
                continue;
            }
            
            // 4. Last resort: try to extract a reasonable key from the numeric value
            NSDebugLog(@"DBusMenuShortcutParser: Unknown keysym %u, using string value", keysymVal);
            key = [self normalizeKeyName:[item stringValue]];
        }
    }
    
    NSString *result = nil;
    if (key && [components count] > 0) {
        result = [NSString stringWithFormat:@"%@+%@", [components componentsJoinedByString:@"+"], key];
    } else if (key) {
        result = key;
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Shortcut parsing result: '%@'", result);
    return result;
}

+ (NSDictionary *)parseKeyCombo:(NSString *)keyCombo
{
    if (!keyCombo || [keyCombo length] == 0) {
        return @{@"key": @"", @"modifiers": @0};
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Parsing key combo: '%@'", keyCombo);
    
    NSUInteger modifierMask = 0;
    NSString *key = @"";
    NSString *work = keyCombo;
    
    // Detect GTK angle-bracket accelerator format: <Control>t, <Primary><Shift>n, <Alt>F4 etc.
    // These use angle brackets around modifiers and no '+' separator.
    if ([work containsString:@"<"] && [work containsString:@">"] && ![work containsString:@"+"]) {
        NSDebugLog(@"DBusMenuShortcutParser: Detected GTK angle-bracket accelerator format");
        
        // Extract modifiers by finding <...> patterns
        while ([work containsString:@"<"] && [work containsString:@">"]) {
            NSRange openRange = [work rangeOfString:@"<"];
            NSRange closeRange = [work rangeOfString:@">"];
            if (openRange.location != NSNotFound && closeRange.location != NSNotFound &&
                closeRange.location > openRange.location) {
                NSRange modRange = NSMakeRange(openRange.location + 1, 
                                               closeRange.location - openRange.location - 1);
                NSString *modName = [self canonicalGTKKeyName:[work substringWithRange:modRange]];
                NSString *lowerMod = [modName lowercaseString];
                
                if ([lowerMod isEqualToString:@"control"] || [lowerMod isEqualToString:@"primary"] ||
                    [lowerMod isEqualToString:@"ctrl"]) {
                    modifierMask |= NSControlKeyMask;
                } else if ([lowerMod isEqualToString:@"shift"]) {
                    modifierMask |= NSShiftKeyMask;
                } else if ([lowerMod isEqualToString:@"alt"]) {
                    modifierMask |= NSAlternateKeyMask;
                } else if ([lowerMod isEqualToString:@"meta"] || [lowerMod isEqualToString:@"super"] ||
                           [lowerMod isEqualToString:@"hyper"] || [lowerMod isEqualToString:@"cmd"] ||
                           [lowerMod isEqualToString:@"command"]) {
                    modifierMask |= NSCommandKeyMask;
                }
                NSDebugLog(@"DBusMenuShortcutParser: GTK format modifier '<%@>' -> mask %lu", 
                      modName, (unsigned long)modifierMask);
                
                // Remove the <...> from the working string
                work = [work stringByReplacingCharactersInRange:NSMakeRange(openRange.location, 
                                                    closeRange.location - openRange.location + 1)
                                                    withString:@""];
            } else {
                break;
            }
        }
        
        // Whatever remains is the key
        key = [self normalizeKeyName:work];
        NSDebugLog(@"DBusMenuShortcutParser: GTK format key: '%@' -> '%@'", work, key);
    } else {
        // Standard '+' separated format (e.g. "Ctrl+T", "control+shift+x", "ctrl+alt+t")
        // Also handle "Control_L+Shift_L+T" etc.
        NSArray *parts = [keyCombo componentsSeparatedByString:@"+"];
        
        for (NSString *part in parts) {
            NSString *cleanPart = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSDebugLog(@"DBusMenuShortcutParser: Processing key combo part: '%@'", cleanPart);
            
            /* GTK renders x-canonical-accel with gtk_accelerator_get_label(),
             * so both the modifiers and the key arrive in the user's language
             * ("Umschalt+Strg+Entf"); put them back into the English names
             * the matching below is written against. */
            cleanPart = [self canonicalGTKKeyName:cleanPart];

            // Case-insensitive modifier matching for Canonical AppMenu compatibility
            // Also handle "_L" and "_R" suffix variants (e.g. "Control_L", "Shift_R")
            NSString *lowerPart = [cleanPart lowercaseString];
            NSString *lowerBase = lowerPart;
            
            // Strip _L / _R suffix for modifier matching
            if ([lowerPart hasSuffix:@"_l"] || [lowerPart hasSuffix:@"_r"]) {
                lowerBase = [lowerPart substringToIndex:[lowerPart length] - 2];
            }
            
            if ([lowerBase isEqualToString:@"cmd"] || [lowerBase isEqualToString:@"command"] ||
                [lowerBase isEqualToString:@"super"] || [lowerBase isEqualToString:@"meta"] ||
                [lowerBase isEqualToString:@"hyper"]) {
                modifierMask |= NSCommandKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Command modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"shift"]) {
                modifierMask |= NSShiftKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Shift modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"alt"] || [lowerBase isEqualToString:@"option"]) {
                modifierMask |= NSAlternateKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Alt modifier mask (from '%@')", cleanPart);
            } else if ([lowerBase isEqualToString:@"ctrl"] || [lowerBase isEqualToString:@"control"]) {
                modifierMask |= NSControlKeyMask;
                NSDebugLog(@"DBusMenuShortcutParser: Added Control modifier mask (from '%@')", cleanPart);
            } else {
                // This should be the key
                key = [self normalizeKeyName:cleanPart];
                NSDebugLog(@"DBusMenuShortcutParser: Set key equivalent: '%@' (from '%@')", key, cleanPart);
            }
        }
    }
    
    NSDebugLog(@"DBusMenuShortcutParser: Key combo result - key: '%@', modifiers: %lu", key, (unsigned long)modifierMask);
    return @{@"key": key, @"modifiers": @(modifierMask)};
}

/* X11 keysym names that have no printable character.  They are returned
 * unchanged so that both the menu renderer and XStringToKeysym() - which is
 * what the global key grab needs - recognise them again. */
/* Reverse of gtk_accelerator_get_label(): the translated label, lowercased,
 * mapped back to the English name.  Built from GTK's own catalogue so it
 * covers every language GTK ships rather than a table maintained here. */
+ (NSDictionary *)localizedGTKKeyNames
{
    static NSDictionary *names = nil;
    static NSString *builtForLocale = nil;

    /* GNUstep does not initialise the C locale, so LC_MESSAGES would still be
     * "C" and GTK's catalogue would answer in English while the app speaks
     * the user's language. */
    const char *localeName = setlocale(LC_MESSAGES, NULL);
    if (localeName == NULL || strcmp(localeName, "C") == 0
            || strcmp(localeName, "POSIX") == 0) {
        localeName = setlocale(LC_MESSAGES, "");
    }

    /* The catalogue answers in whatever LC_MESSAGES is set to; a language
     * change has to rebuild the map. */
    NSString *locale = localeName ? [NSString stringWithUTF8String:localeName] : @"";

    if (names != nil && [builtForLocale isEqualToString:locale]) {
        return names;
    }

    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < NUM_GTK_KEYBOARD_LABELS; i++) {
        const char *english = gtk_keyboard_labels[i];

        /* GNU gettext encodes a message context as "context\004msgid" and
         * returns that whole string again when there is no translation. */
        char msgid[64];
        snprintf(msgid, sizeof(msgid), "keyboard label%c%s", '\004', english);

        for (NSUInteger d = 0; d < NUM_GTK_TEXT_DOMAINS; d++) {
            const char *translated = dgettext(gtk_text_domains[d], msgid);
            if (translated == NULL || strcmp(translated, msgid) == 0) {
                continue;
            }

            NSString *localized = [[NSString stringWithUTF8String:translated] lowercaseString];
            if ([localized length] > 0 && [map objectForKey:localized] == nil) {
                [map setObject:[NSString stringWithUTF8String:english] forKey:localized];
            }
            break;
        }
    }

    names = [[NSDictionary alloc] initWithDictionary:map];
    builtForLocale = [[NSString alloc] initWithString:locale];
    NSDebugLog(@"DBusMenuShortcutParser: %lu localized GTK key names for locale '%@'",
          (unsigned long)[names count], locale);
    return names;
}

+ (NSString *)canonicalGTKKeyName:(NSString *)name
{
    if ([name length] == 0) {
        return name;
    }

    NSString *english = [[self localizedGTKKeyNames] objectForKey:[name lowercaseString]];
    return english ?: name;
}

+ (NSString *)namedKeyEquivalentFor:(NSString *)lowerName
{
    static NSDictionary *namedKeys = nil;

    /* The cache takes ownership explicitly rather than storing the literal,
     * so it survives a pool drain whether or not this file is compiled with
     * ARC (the unit test includes it without). */
    if (namedKeys == nil) {
        NSDictionary *keys = @{
            @"up":          @"Up",
            @"down":        @"Down",
            @"left":        @"Left",
            @"right":       @"Right",
            @"kp_up":       @"Up",
            @"kp_down":     @"Down",
            @"kp_left":     @"Left",
            @"kp_right":    @"Right",
            @"home":        @"Home",
            @"kp_home":     @"Home",
            @"end":         @"End",
            @"kp_end":      @"End",
            @"page_up":     @"Page_Up",
            @"prior":       @"Page_Up",
            @"kp_page_up":  @"Page_Up",
            @"page_down":   @"Page_Down",
            @"next":        @"Page_Down",
            @"kp_page_down":@"Page_Down",
            @"insert":      @"Insert",
            @"kp_insert":   @"Insert",
            @"delete":      @"Delete",
            @"delete_key":  @"Delete",
            @"kp_delete":   @"Delete",
            @"menu":        @"Menu",
            @"print":       @"Print",
            @"pause":       @"Pause",
        };
        namedKeys = [[NSDictionary alloc] initWithDictionary:keys];
    }

    return [namedKeys objectForKey:lowerName];
}

/* GTK / X11 spell punctuation keys out ("equal", "minus"); a menu has to show
 * the character the user actually presses. */
+ (NSString *)characterKeyEquivalentFor:(NSString *)lowerName
{
    static NSDictionary *characterKeys = nil;

    if (characterKeys == nil) {
        NSDictionary *keys = @{
            @"minus": @"-",
            @"equal": @"=",
            @"bracketleft": @"[",
            @"bracketright": @"]",
            @"semicolon": @";",
            @"apostrophe": @"'",
            @"comma": @",",
            @"period": @".",
            @"slash": @"/",
            @"backslash": @"\\",
            @"grave": @"`",
            @"asciitilde": @"~",
            @"exclam": @"!",
            @"at": @"@",
            @"numbersign": @"#",
            @"dollar": @"$",
            @"percent": @"%",
            @"asciicircum": @"^",
            @"ampersand": @"&",
            @"asterisk": @"*",
            @"parenleft": @"(",
            @"parenright": @")",
            @"underscore": @"_",
            @"plus": @"+",
            @"braceleft": @"{",
            @"braceright": @"}",
            @"colon": @":",
            @"quotedbl": @"\"",
            @"less": @"<",
            @"greater": @">",
            @"question": @"?",
            @"bar": @"|",
            @"kpad_add": @"+",
            @"kp_add": @"+",
            @"kpad_subtract": @"-",
            @"kp_subtract": @"-",
            @"kpad_multiply": @"*",
            @"kp_multiply": @"*",
            @"kpad_divide": @"/",
            @"kp_divide": @"/",
            @"kpad_0": @"0",
            @"kpad_1": @"1",
            @"kpad_2": @"2",
            @"kpad_3": @"3",
            @"kpad_4": @"4",
            @"kpad_5": @"5",
            @"kpad_6": @"6",
            @"kpad_7": @"7",
            @"kpad_8": @"8",
            @"kpad_9": @"9",
        };
        characterKeys = [[NSDictionary alloc] initWithDictionary:keys];
    }

    return [characterKeys objectForKey:lowerName];
}

+ (NSString *)functionKeyEquivalentFor:(NSString *)lowerName
{
    if ([lowerName length] < 2 || [lowerName length] > 3
            || [lowerName characterAtIndex:0] != 'f') {
        return nil;
    }

    NSString *digits = [lowerName substringFromIndex:1];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([digits rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return nil;
    }

    int number = [digits intValue];
    if (number < 1 || number > 35) {
        return nil;
    }

    return [NSString stringWithFormat:@"F%d", number];
}

+ (BOOL)isFunctionKeyEquivalent:(NSString *)keyEquivalent
{
    if ([keyEquivalent length] == 0) {
        return NO;
    }

    return [self functionKeyEquivalentFor:[keyEquivalent lowercaseString]] != nil;
}

+ (BOOL)shouldRegisterGlobalShortcutForKey:(NSString *)keyEquivalent
                                 modifiers:(NSUInteger)modifierMask
{
    if ([keyEquivalent length] == 0) {
        return NO;
    }

    /* A bare or Shift-only key would be grabbed away from every text field on
     * the desktop.  Function keys are the exception: an exported menu bar
     * takes the toolkit's own accelerator group with it, so nothing else can
     * still deliver them to the application. */
    if (modifierMask == 0 || modifierMask == NSShiftKeyMask) {
        return [self isFunctionKeyEquivalent:keyEquivalent];
    }

    return YES;
}

+ (NSString *)normalizeKeyName:(NSString *)keyName
{
    if (!keyName || [keyName length] == 0) {
        return @"";
    }
    
    // Normalise to lowercase for case-insensitive matching
    NSString *normalized = [[self canonicalGTKKeyName:keyName] lowercaseString];
    
    // Handle special keys - also check common GTK-X11 keysym names
    if ([normalized isEqualToString:@"return"] || [normalized isEqualToString:@"enter"] ||
        [normalized isEqualToString:@"kp_enter"] || [normalized isEqualToString:@"kpad_enter"]) {
        return @"\r";
    } else if ([normalized isEqualToString:@"tab"] || [normalized isEqualToString:@"kpad_tab"]) {
        return @"\t";
    } else if ([normalized isEqualToString:@"space"] || [normalized isEqualToString:@"kpad_space"]) {
        return @" ";
    } else if ([normalized isEqualToString:@"escape"] || [normalized isEqualToString:@"esc"]) {
        return @"\033";
    } else if ([normalized isEqualToString:@"backspace"] || [normalized isEqualToString:@"back_space"] ||
               [normalized isEqualToString:@"back"]) {
        return @"\b";
    }

    NSString *functionKey = [self functionKeyEquivalentFor:normalized];
    if (functionKey) {
        return functionKey;
    }

    NSString *namedKey = [self namedKeyEquivalentFor:normalized];
    if (namedKey) {
        return namedKey;
    }

    NSString *characterKey = [self characterKeyEquivalentFor:normalized];
    if (characterKey) {
        return characterKey;
    }
    
    // Single character - ensure lowercase
    if ([normalized length] == 1) {
        return normalized;
    }
    
    /* Unknown multi-character keysym name: keep it when X11 knows it (the grab
     * needs the name, not a character), otherwise use the character it
     * stands for. */
    KeySym sym = XStringToKeysym([keyName UTF8String]);
    if (sym == NoSymbol) {
        sym = XStringToKeysym([normalized UTF8String]);
    }
    if (sym != NoSymbol) {
        if (sym >= 0x20 && sym <= 0x7E) {
            unichar c = (unichar)sym;
            return [NSString stringWithCharacters:&c length:1];
        }
        char *canonical = XKeysymToString(sym);
        if (canonical) {
            return [NSString stringWithUTF8String:canonical];
        }
    }

    NSDebugLog(@"DBusMenuShortcutParser: Unknown key name '%@' - using its first character", keyName);
    return [normalized substringToIndex:1];
}

+ (KeySym)keysymForKeyEquivalent:(NSString *)keyEquivalent
{
    if ([keyEquivalent length] == 0) {
        return NoSymbol;
    }

    if ([keyEquivalent length] == 1) {
        unichar c = [keyEquivalent characterAtIndex:0];

        switch (c) {
            case '\r': case '\n': return XK_Return;
            case '\t':            return XK_Tab;
            case '\033':          return XK_Escape;
            case '\b':            return XK_BackSpace;
            case '\177':          return XK_Delete;
            default: break;
        }

        /* X11 keysyms coincide with the code point over ASCII and Latin-1, so
         * a printable key equivalent needs no name lookup at all - and for
         * "=" or "-" there is none, X11 only knows "equal" and "minus". */
        if (c >= 0x20 && c <= 0xFF) {
            if (c >= 'A' && c <= 'Z') {
                c = c - 'A' + 'a';
            }
            return (KeySym)c;
        }

        return NoSymbol;
    }

    /* Multi-character key equivalents are X11 keysym names ("Up", "Page_Up",
     * "F5"), which normalizeKeyName: has already canonicalised. */
    KeySym sym = XStringToKeysym([keyEquivalent UTF8String]);
    if (sym != NoSymbol) {
        return sym;
    }

    NSString *canonical = [self normalizeKeyName:keyEquivalent];
    if (![canonical isEqualToString:keyEquivalent]) {
        return [self keysymForKeyEquivalent:canonical];
    }

    return NoSymbol;
}

+ (NSString *)modifierMaskToString:(NSUInteger)modifierMask
{
    NSMutableArray *modifiers = [NSMutableArray array];
    
    if (modifierMask & NSCommandKeyMask) {
        [modifiers addObject:@"⌘"];
    }
    if (modifierMask & NSShiftKeyMask) {
        [modifiers addObject:@"⇧"];
    }
    if (modifierMask & NSAlternateKeyMask) {
        [modifiers addObject:@"⌥"];
    }
    if (modifierMask & NSControlKeyMask) {
        [modifiers addObject:@"⌃"];
    }
    
    return [modifiers componentsJoinedByString:@""];
}

+ (NSDictionary *)testParseKeyCombo:(NSString *)keyCombo
{
    return [self parseKeyCombo:keyCombo];
}

@end
