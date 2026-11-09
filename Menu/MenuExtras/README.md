# Menu Extras — Developer Guide

This directory contains standalone `.gsmenuextra` bundles loaded at runtime
by `MenuExtraManager`. Items appear on the right side of the menu bar.

## Protocol: `GSMenuExtra`

Every extra must conform to `GSMenuExtra` (`GSMenuExtra.h`).

### Required

```objc
- (NSString *)title;            // Displayed text
- (CGFloat)width;               // Cached pixel width
- (void)setManager:(MenuExtraManager *)manager;
```

### Optional

```objc
- (void)update;                 // Timer refresh
- (void)handleClick;            // Click handler
- (NSMenu *)menu;               // Dropdown menu
- (NSImage *)icon;              // 16x16 icon before title
- (void)unload;                 // Cleanup
- (NSInteger)displayPriority;   // Lower = more left (default: 100)
- (void)menuWillOpen;
- (void)menuDidClose;
```

### displayPriority

Lower values appear **leftmost**. Current assignments:

- Brightness: `10`, Sound: `20`, WLAN: `30`, Battery: `40`, Clock: `50`,
  BuildMonitor: `60`, Time: `70`

### Bundle Structure

```
MenuExtras/MyExtra/
├── GNUmakefile
├── Info.plist
├── MyExtra.h
├── MyExtra.m
└── MyExtra.gsmenuextra/ (built)
```

### GNUmakefile

```makefile
include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = MyExtra
BUNDLE_EXTENSION = .gsmenuextra
MyExtra_OBJC_FILES = MyExtra.m
MyExtra_HEADER_FILES = MyExtra.h
MyExtra_RESOURCE_FILES = Info.plist
MyExtra_PRINCIPAL_CLASS = MyExtra
MyExtra_INSTALL_DIR = /System/Library/MenuExtras

include $(GNUSTEP_MAKEFILES)/bundle.make
```

### Info.plist

```xml
<key>NSPrincipalClass</key>
<string>MyExtra</string>
```

Identifier is set by the bundle name, not from Info.plist.

## Enabled by default

An extra that a media key or a hardware button acts on belongs in the menu
bar from the moment it is installed, rather than waiting to be found in the
preferences. Such an extra implements:

```objc
- (BOOL)enabledByDefault;   // YES
```

and `MenuExtraManager` puts its identifier into the saved `GSMenuExtraEnabled`
set the first time it sees it, and writes the user's own set back. It is
added to the set, not shown in spite of it: unticking it afterwards removes
it for good, exactly like unticking any other extra. `MediaExtra` is the one
that asks.

## Extras that are built only where they can work

An extra that cannot do anything without a library is left out of the build
and out of the installation where that library is missing, and is skipped
quietly rather than failing. `MediaExtra` steers media players over MPRIS2,
so it is built only where `libdbus` is; Menu's own `GNUmakefile` compiles a
one-line program against `<dbus/dbus.h>` and `$(DBUS_LIBS)` to find out, and
the two lists of extras - the directories to build and the bundles to
install - are kept in `MENU_EXTRA_DIRS` and `MENU_EXTRA_BUNDLES` so they
cannot disagree.

The rest of the media hub is not conditional: `MediaHub` is part of Menu
itself, so where libdbus is missing the Distributed Objects interface still
answers and still steers the native Gershwin player. Only the menu bar item
is lost, which is the right thing to lose - an item that can do nothing is
worse than no item.

## Available Extras

- **ClockExtra** — Time display
- **BatteryExtra** — Battery level and charging status
- **WLANExtra** — Wireless signal strength
- **SoundExtra** — Volume level
- **BrightnessExtra** — Display brightness
- **BuildMonitorExtra** — Build system monitor
- **MediaExtra** — Play/pause, next, previous, and which player is playing
- **TimeDisplay** — Digital clock (TimeExtra)
