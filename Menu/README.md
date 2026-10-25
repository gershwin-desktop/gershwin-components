# Menu.app for GNUstep

A GNUstep port of the Menu global menu bar application with DBus app menu support.

## Overview

This application provides a global menu bar that displays application menus at the top of the screen. It uses DBus to communicate with applications that export their menus using either:
* The Canonical protocol (`com.canonical.AppMenu.Registrar` and `com.canonical.dbusmenu`) (applications export their menus to Menu.app), or
* The GTK protocol (`org.gtk.Menus` and `org.gtk.Actions`) (Menu.app queries applications for their menus), or
* The native GNUstep protocol (still to be implemented)

## Features

- Global menu bar displayed at the top of the screen
- DBus-based application menu import supporting the Canonical and the GTK protocols
- Advanced anti-flicker mechanisms for seamless menu transitions
- GNUstep/Objective-C implementation
- No glib/gio dependencies (uses libdbus directly)

## Dependencies

### Required Libraries for Building
- GNUstep Base (`gnustep-base-dev`)
- GNUstep GUI (`gnustep-gui-dev`) 
- libdbus-1 (`libdbus-1-dev`), optional - see [Building without D-Bus](#building-without-d-bus)
- X11 libraries (`libx11-dev`)

### Build Tools
- GNUstep Make (`gnustep-make`)
- clang19 compiler
- GNU Make (`gmake`)

## Building

```bash
# Make sure GNUstep environment is set up
. /usr/share/GNUstep/Makefiles/GNUstep.sh

# Build the application
gmake clean
gmake

# Install system-wide
sudo gmake install
```

### Building without D-Bus

D-Bus only carries the menus of Qt and GTK programs (the Canonical and GTK
protocols above); GNUstep programs hand their menus over by Distributed
Objects and need no bus.  D-Bus is therefore built in only when libdbus is
found and the system is not NextBSD, which ships no D-Bus.  Without it the
D-Bus importers, Menu's bus connection and the MPRIS2 side of the media hub
are not compiled and nothing links `-ldbus-1`: GNUstep menus work as before,
and the menus of Qt and GTK programs stay in their windows.

To leave D-Bus out anywhere, run `./configure --without-dbus`, or pass
`MENU_DBUS=no` to `gmake` (`MENU_DBUS=yes` requires it, the default is
`auto`).  The unit tests in `Tests/Unit` follow the same switch.

## Installation

The application will be installed to `/System/Library/CoreServices/Applications/Menu.app`.

## Usage

### Starting the Menu Bar

```bash
# Start from command line
/System/Library/CoreServices/Applications/Menu.app/Menu

# Or launch using openapp
openapp Menu
```

### Application Integration

Applications can export their menus to the global menu bar by implementing the DBus menu specification:

1. Register with the `com.canonical.AppMenu.Registrar` service
2. Export menus using the `com.canonical.dbusmenu` interface
3. Set window properties to associate menus with windows

## Technical Details

### Architecture

- **MenuController**: Main application controller, manages the menu bar window
- **MenuBarView**: Custom view that renders the menu bar background
- **AppMenuWidget**: Widget that displays application menus as buttons
- **DBusMenuImporter**: Handles DBus communication for menu import
- **DBusConnection**: Low-level DBus wrapper (no glib dependencies)
- **MenuUtils**: X11 utilities for window management

### DBus Interfaces

The application implements these DBus interfaces:

- `com.canonical.AppMenu.Registrar` - For applications to register their menus
- `com.canonical.dbusmenu` - For accessing exported application menus

### Window Management

Uses X11 directly to:
- Track the active window
- Get window properties
- Monitor window focus changes

### Anti-Flicker Mechanisms

Multiple layers of protection prevent menu flickering during window switches:

1. **Deferred Menu Clearing**: New menu loads before old menu is cleared, eliminating visual gaps
2. **Smart Shortcut Management**: Shortcuts only cleared when switching to different application (PID-based detection)
3. **Same-PID Window Switching**: Instant menu preservation when switching between windows of same app
4. **Grace Period for Window==0**: 0.2s grace period when focus goes to "no window" to handle rapid window switches
5. **Grace Period for No-Menu Apps**: 0.2s grace period when switching to apps without menus, giving them time to register

**Result**: Smooth, flicker-free menu transitions in all scenarios

### D-Bus Message Processing

Reliable D-Bus service operation ensured by:
- Timer-based polling (50ms interval) as primary mechanism
- NSFileHandle monitoring as secondary mechanism
- Guarantees services like `com.canonical.AppMenu.Registrar` and `org.freedesktop.FileManager1` work correctly
## Troubleshooting

### Menu Flickering or Disappearing

If you experience menu flickering when switching windows:

**Check the logs for these patterns:**

1. **Duplicate "Active window is 0" notifications**
   - Should only see ONE notification per actual window change
   - If you see floods of identical notifications, WindowMonitor deduplication may have regressed
   - Check `WindowMonitor.m:checkActiveWindow` has proper `if (newActiveWindow != _currentActiveWindow)` guard

2. **"Watchdog detected invalid/closed window" clearing active window's menu**
   - Watchdog should NOT clear menu if `shownWindow == activeWindow` and menu exists
   - Check `MenuController.m:windowValidationTick` has protection: "If shown window IS the active window AND we have a menu for it, DON'T clear it"

3. **"Grace period expired" clearing wrong window's menu**
   - Timer should check `if (self.currentWindowId != windowId)` and return early
   - Check `AppMenuWidget.m:noMenuGracePeriodExpired` validates window hasn't changed

4. **Menu clears immediately when window==0**
   - Should preserve menu for 0.2s grace period
   - Check `MenuController.m` routes through `updateForActiveWindowId`, not direct `clearMenuAndHideView`

### DBus Connection Issues

If the application fails to connect to DBus:

```bash
# Check if DBus session is running
echo $DBUS_SESSION_BUS_ADDRESS

# Start DBus session if needed
eval `dbus-launch --auto-syntax`
```

### D-Bus Services Not Working

If `org.freedesktop.FileManager1` or `com.canonical.AppMenu.Registrar` don't work:

1. **Check D-Bus polling timer is running**
   - Log should show "D-Bus polling timer set up (50ms interval)"
   - Timer ensures messages are processed even if file descriptor monitoring fails

2. **Verify service registration**
   - Log should show "Successfully registered as AppMenu.Registrar service"
   - If not, another menu application may own the service

### Menu Not Appearing for Application

If an application's menu doesn't appear:

1. **Check if app exports menus**
   ```bash
   # List D-Bus services
   dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply \
     /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep -i menu
   ```

2. **Check window properties**
   ```bash
   # Get active window ID
   xprop -root _NET_ACTIVE_WINDOW
   
   # Check if window has menu properties
   xprop -id <WINDOW_ID> | grep -i menu
   ```

3. **Enable debug logging**
   - Look for "No registered menu for window" messages
   - Grace period timer should give app 0.2s to register
   - If menu appears after grace period, increase timeout or fix app registration timing

### X11 "BadWindow" Errors

If you see X11 errors in logs:

- **Expected during window close**: Windows may become invalid during destruction
- **WindowMonitor protection**: Automatically handles BadWindow by trusting window manager
- **Not expected during normal operation**: If seeing frequent errors during normal window switches, window manager may not be setting `_NET_ACTIVE_WINDOW` properly

### High CPU Usage

If Menu.app uses excessive CPU:

1. **Check for notification floods**
   - Should see max 1-2 notifications per window switch
   - Floods indicate WindowMonitor deduplication bug

2. **Check D-Bus polling**
   - 50ms interval is normal (2% CPU max)
   - If higher, D-Bus message processing may be hanging

3. **Check watchdog timer**
   - Should skip validation for active windows with menus
   - Excessive X11 queries indicate protection logic not working

## Development

### GNUstep Environment

Make sure GNUstep environment is properly configured:

```bash
# Source the GNUstep environment
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh

# Check environment variables
echo $GNUSTEP_SYSTEM_ROOT
echo $GNUSTEP_LOCAL_ROOT
```

### Testing

- Qt application (qvlc) with `QT_QPA_PLATFORMTHEME=kde`
- GTK 2 application (leafpad) with appmenu-gtk-module
- GTK 2 application (gedit) with appmenu-gtk-module

## Contributing

When contributing:
- Follow the existing code style
- Add extensive logging for debugging
- Test with real applications
- Ensure no glib dependencies are introduced
- Use manual memory management (no ARC)
