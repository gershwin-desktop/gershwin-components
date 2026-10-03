#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause
# End to end: GTK 3 apps with the module loaded talk to a mock Menu.app.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$(mktemp -d "${TMPDIR:-/tmp}/gad-smoke.XXXXXX")
mkdir -p "$OUT/modules"
cp obj/libgtk-appmenu-do.so "$OUT/modules/"
export GTK_PATH=$OUT GTK_MODULES=gtk-appmenu-do
export GNUSTEP_USER_ROOT=$OUT/gs

fail=0
check() { # name file pattern
  grep -q -- "$3" "$2" || { echo "FAIL [$1]: missing $3"; fail=1; }
}

run() { # name script activate-path
  export GAD_MENU_SERVER_NAME=org.gnustep.Gershwin.MenuServer.GadTest$$$1
  xvfb-run -a bash -c '
    MOCK_ACTIVATE_PATH=$3 "$0"/obj/mock-menu-server > "$1/$2.server" 2>&1 &
    SERVER=$!
    sleep 1
    if [ -x "$1/$2" ]; then "$1/$2" 8; else python3 "$0"/tests/$2.py 8; fi > "$1/$2.app" 2>&1
    kill $SERVER
  ' "$ROOT" "$OUT" "$2" "$3"
  check "$1" "$OUT/$2.server" "UPDATE window="
}

run gtk3 gtk3-app 0,0
S=$OUT/gtk3-app.server
check gtk3 $S "keyEquivalent = o; keyEquivalentModifierMask = 1048576; shortcutViaMenu = 1; state = 0; title = Open"
check gtk3 $S "state = 1; title = Wrap"
check gtk3 $S "keyEquivalent = k; keyEquivalentModifierMask = 1048576; shortcutViaMenu = 1; state = 0; title = Own"
check gtk3 $S "title = Paste"
check gtk3 $S "title = Zoom"
check gtk3 $S "title = \"Recent 1\""
check gtk3 $S "REFRESH {items = ("
check gtk3 $S "title = \"Recent 2\""
check gtk3 $S "title = Options"
check gtk3 $OUT/gtk3-app.app "MAPPED TOPLEVELS 1"
check gtk3 $OUT/gtk3-app.app "MENUBAR VISIBLE False"
check gtk3 $OUT/gtk3-app.app "ACTIVATED Open"

run gmenu gtk3-gmenu-app 0,0
check gmenu $OUT/gtk3-gmenu-app.server "keyEquivalent = e; keyEquivalentModifierMask = 1048576; shortcutViaMenu = 1; state = 0; title = Export"
check gmenu $OUT/gtk3-gmenu-app.app "ACTIVATED Export"

# GTK 2 needs its headers for the test program only; the module never does.
if pkg-config --exists gtk+-2.0; then
  cc -o "$OUT/gtk2-app" tests/gtk2-app.c $(pkg-config --cflags --libs gtk+-2.0) -Wno-deprecated-declarations
  run gtk2 gtk2-app 0,0
  check gtk2 $OUT/gtk2-app.server "keyEquivalent = o; keyEquivalentModifierMask = 1048576; shortcutViaMenu = 1; state = 0; title = Open"
  check gtk2 $OUT/gtk2-app.app "ACTIVATED Open"
fi

[ -n "${GAD_KEEP:-}" ] && cp $OUT/gtk3-app.app $GAD_KEEP
[ $fail = 0 ] && echo "PASS" || { tail -n 20 $OUT/*.server $OUT/*.app; }
rm -rf "$OUT"
exit $fail
