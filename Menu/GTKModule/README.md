# GTKModule (gtk-appmenu-do)

Part of Menu: the protocol it speaks is `../GNUStepMenuIPC.h`.

GTK module that shows the menu bar of GTK 2 and GTK 3 applications in Menu.app,
using the same Distributed Objects protocol (`org.gnustep.Gershwin.MenuServer` /
`org.gnustep.Gershwin.MenuClient.<pid>`) that GNUstep applications use through
the Eau theme. No D-Bus involved.

Built without GTK, GDK or GLib headers: the module is loaded into a process that
already runs GTK and resolves everything it needs with `dlsym`. One binary serves
GTK 2 and GTK 3. Build time needs only GNUstep base.

    make
    make install        # PREFIX defaults to /System/Library/Libraries/gtk-appmenu-do
    export GTK_PATH=/System/Library/Libraries/gtk-appmenu-do GTK_MODULES=gtk-appmenu-do

`make check` runs a GTK 3 test app against a mock Menu.app on a private Xvfb display
(`GAD_MENU_SERVER_NAME` renames the server so a running Menu.app is not touched).

## How it works

- `src/module.c`: on the first map of a `GtkMenuBar` it walks the item tree, pushes it
  to Menu.app, hides the in-window menu bar while Menu.app is reachable, and pushes
  again (debounced 100 ms) when items are added, removed, renamed, enabled or checked.
  Activation and state validation requests from Menu.app are run on the GTK main loop.
- `src/bridge.m`: Foundation-only DO side on its own thread; registers the client name,
  reconnects to the server, converts the item tree to the dictionaries Menu.app expects.

## Tests

    make test     # ObjectTesting unit tests (tests/Unit)
    make check    # unit tests plus end to end runs: GTK 3 (menu, key equivalents,
                  # check state, menus filled on "show", GMenuModel menu bar) and,
                  # when its headers exist, a GTK 2 program

## Known limitations

- A menu found empty is filled by emitting "show", "select" (undone at once) and
  "activate" once; the signal that worked is remembered. When the user starts using
  the menu bar, Menu.app calls `refreshedMenuDataForWindow:`, the module emits that
  signal again and Menu.app exchanges the items of submenus that changed. Menu.app
  with this support is required for menus an application rebuilds on every use.
- Key equivalents beyond printable Latin-1 characters (function keys, arrows) are not
  passed on.
- GTK 4 has no module mechanism.
