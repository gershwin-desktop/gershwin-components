/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Accelerators of imported foreign menus must survive the trip from the
   toolkit's key name to an NSMenuItem key equivalent and back to an X11
   keysym.  GTK apps driven through appmenu-gtk-module lose their own
   accelerator group, so whatever is dropped here is a shortcut the user can
   no longer press at all.  Headless: no display needed. */

#import <AppKit/AppKit.h>
#import <X11/Xlib.h>
#import <X11/keysym.h>
#include <locale.h>
#import "Testing.h"
#include "../../DBusMenuShortcutParser.m"

/* The key equivalent GTK's accel string produces. */
static NSString *KeyFor(NSString *accel)
{
  return [[DBusMenuShortcutParser parseKeyCombo: accel] objectForKey: @"key"];
}

static NSUInteger ModsFor(NSString *accel)
{
  return [[[DBusMenuShortcutParser parseKeyCombo: accel]
            objectForKey: @"modifiers"] unsignedIntegerValue];
}

/* A key equivalent is only usable once X11 can turn it back into a keysym,
   which is what the global grab needs. */
static KeySym KeysymFor(NSString *keyEquivalent)
{
  return [DBusMenuShortcutParser keysymForKeyEquivalent: keyEquivalent];
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  START_SET("gtk accelerator key names");

  PASS_EQUAL(KeyFor(@"<Primary>o"), @"o", "a plain letter stays a letter");
  PASS(ModsFor(@"<Primary>o") == NSControlKeyMask, "<Primary> is Control");
  PASS(ModsFor(@"<Primary><Shift>s") == (NSControlKeyMask | NSShiftKeyMask),
       "<Primary><Shift> is Control plus Shift");

  /* Viking's zoom items: GDK spells the characters out. */
  PASS_EQUAL(KeyFor(@"<Primary>equal"), @"=", "equal is the = character");
  PASS_EQUAL(KeyFor(@"<Primary>minus"), @"-", "minus is the - character");
  PASS_EQUAL(KeyFor(@"<Primary>percent"), @"%", "percent is a single character");

  /* Viking pans the map with Control plus an arrow key. */
  PASS_EQUAL(KeyFor(@"<Primary>Up"), @"Up", "Up keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Down"), @"Down", "Down keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Left"), @"Left", "Left keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Right"), @"Right", "Right keeps its keysym name");

  PASS_EQUAL(KeyFor(@"<Primary>Delete"), @"Delete", "Delete keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Home"), @"Home", "Home keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>End"), @"End", "End keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Page_Up"), @"Page_Up", "Page_Up keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Page_Down"), @"Page_Down",
             "Page_Down keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>Insert"), @"Insert", "Insert keeps its keysym name");
  PASS_EQUAL(KeyFor(@"<Primary>BackSpace"), @"\b", "BackSpace is the control character");

  /* Function keys carry no modifier at all in most GTK apps. */
  PASS_EQUAL(KeyFor(@"F5"), @"F5", "a bare function key survives");
  PASS(ModsFor(@"F5") == 0, "a bare function key has no modifier");
  PASS_EQUAL(KeyFor(@"F11"), @"F11", "a two-digit function key survives");
  PASS_EQUAL(KeyFor(@"<Shift>F10"), @"F10", "Shift plus function key keeps the key");
  PASS(ModsFor(@"<Shift>F10") == NSShiftKeyMask, "Shift plus function key keeps Shift");

  END_SET("gtk accelerator key names");

  START_SET("localized gtk accelerator labels");

  /* GIMP and other GTK apps send x-canonical-accel as
     gtk_accelerator_get_label() rendered it, so both the modifier and the key
     name arrive in the user's language.  Asking GTK's own catalogue turns
     them back; skip the set where GTK's German catalogue is not installed. */
  setlocale(LC_MESSAGES, "de_DE.UTF-8");
  if (![[DBusMenuShortcutParser canonicalGTKKeyName: @"Strg"] isEqualToString: @"Ctrl"])
    {
      SKIP("GTK's German message catalogue is not installed");
    }
  else
    {
      PASS_EQUAL([DBusMenuShortcutParser canonicalGTKKeyName: @"Umschalt"], @"Shift",
                 "Umschalt is Shift");
      PASS_EQUAL([DBusMenuShortcutParser canonicalGTKKeyName: @"Entf"], @"Delete",
                 "Entf is Delete");
      PASS_EQUAL([DBusMenuShortcutParser canonicalGTKKeyName: @"Eingabe"], @"Return",
                 "Eingabe is Return");

      PASS_EQUAL(KeyFor(@"Strg+W"), @"w", "Strg+W keeps the letter");
      PASS(ModsFor(@"Strg+W") == NSControlKeyMask, "Strg is Control");
      PASS(ModsFor(@"Umschalt+Strg+S") == (NSControlKeyMask | NSShiftKeyMask),
           "Umschalt+Strg is Shift plus Control");
      PASS(ModsFor(@"Strg+Alt+O") == (NSControlKeyMask | NSAlternateKeyMask),
           "Strg+Alt is Control plus Alt");
      PASS_EQUAL(KeyFor(@"Entf"), @"Delete", "a bare Entf is the Delete key");
      PASS_EQUAL(KeyFor(@"Alt+Eingabe"), @"\r", "Alt+Eingabe is Alt plus Return");
      PASS(ModsFor(@"Alt+Eingabe") == NSAlternateKeyMask, "Alt+Eingabe keeps Alt");
      PASS_EQUAL(KeyFor(@"Strg+,"), @",", "a punctuation key survives translation");
    }
  setlocale(LC_MESSAGES, "C");

  END_SET("localized gtk accelerator labels");

  START_SET("key equivalents resolve to X11 keysyms");

  NSArray *accels = [NSArray arrayWithObjects:
                       @"<Primary>o", @"<Primary>equal", @"<Primary>minus",
                       @"<Primary>Up", @"<Primary>Down", @"<Primary>Left",
                       @"<Primary>Right", @"<Primary>Delete", @"<Primary>Home",
                       @"<Primary>End", @"<Primary>Page_Up", @"<Primary>Page_Down",
                       @"<Primary>Insert", @"<Primary>BackSpace",
                       @"F1", @"F5", @"F11", @"<Shift>F10", nil];
  NSEnumerator *e = [accels objectEnumerator];
  NSString *accel;
  while ((accel = [e nextObject]) != nil)
    {
      NSString *key = KeyFor(accel);
      PASS(KeysymFor(key) != NoSymbol,
           "%s yields a key equivalent X11 understands",
           [[NSString stringWithFormat: @"%@ ('%@')", accel, key] UTF8String]);
    }

  END_SET("key equivalents resolve to X11 keysyms");

  START_SET("global registration policy");

  /* Bare letters must never be grabbed globally - they would be stolen from
     every text field on the desktop. */
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @"n"
                                                        modifiers: 0] == NO,
       "a bare letter is not grabbed globally");
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @"n"
                                                        modifiers: NSShiftKeyMask] == NO,
       "Shift plus a letter is not grabbed globally");
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @"n"
                                                        modifiers: NSCommandKeyMask],
       "Command plus a letter is grabbed globally");
  /* Function keys are the one modifier-less case: the GTK app cannot react to
     them itself once its menu bar has been exported. */
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @"F5"
                                                        modifiers: 0],
       "a bare function key is grabbed globally");
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @"F10"
                                                        modifiers: NSShiftKeyMask],
       "Shift plus a function key is grabbed globally");
  PASS([DBusMenuShortcutParser shouldRegisterGlobalShortcutForKey: @""
                                                        modifiers: NSCommandKeyMask] == NO,
       "an empty key equivalent is not grabbed globally");

  END_SET("global registration policy");

  [pool release];
  return 0;
}
