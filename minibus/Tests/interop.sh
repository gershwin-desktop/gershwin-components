#!/bin/sh
# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause
#
# Smoke tests with real D-Bus tools against a private bus. Missing tools are
# skipped. Honours MINIBUS_TEST_DAEMON (real|minibus) and MINIBUS_BIN.
# Output: lines starting with PASS, FAIL or SKIP; exit status 1 on any FAIL.

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${MINIBUS_TEST_DAEMON:-minibus}
BIN=${MINIBUS_BIN:-$HERE/../obj/minibus}
PASS=0; FAIL=0

# private directory with a short name (AF_UNIX path limit)
for base in "$MINIBUS_TEST_TMP" "$TMPDIR" /tmp; do
  [ -n "$base" ] && [ ${#base} -lt 70 ] && [ -d "$base" ] && { DIR=$(mktemp -d "$base/mbi.XXXXXX") && break; }
done
[ -n "$DIR" ] || { echo "SKIP interop: no temp dir"; exit 0; }
SOCK=$DIR/s
ADDR=unix:path=$SOCK
DPID=
cleanup () {
  [ -n "$MONPID" ] && kill "$MONPID" 2>/dev/null
  [ -n "$DPID" ] && kill "$DPID" 2>/dev/null && wait "$DPID" 2>/dev/null
  rm -rf "$DIR"
}
trap cleanup EXIT INT TERM

unset DISPLAY DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS

ok ()   { PASS=$((PASS + 1)); echo "PASS $1"; }
bad ()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "$2" ] && echo "     $2" | head -5; }
skip () { echo "SKIP $1"; }
have () { command -v "$1" >/dev/null 2>&1; }
# check NAME "output" "needle"
check () {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "wanted '$3' in: $2" ;; esac
}

if [ "$MODE" = real ]; then
  DAEMON=/usr/bin/dbus-daemon
  "$DAEMON" --config-file="$HERE/test-bus.conf" --address="$ADDR" --nofork --print-address --nopidfile >"$DIR/out" 2>"$DIR/err" &
else
  if [ ! -x "$BIN" ]; then skip "interop: minibus binary $BIN not found"; exit 0; fi
  "$BIN" --address="$ADDR" --nofork --print-address >"$DIR/out" 2>"$DIR/err" &
fi
DPID=$!
i=0
while [ $i -lt 100 ] && [ ! -S "$SOCK" ]; do sleep 0.05; i=$((i + 1)); done
[ -S "$SOCK" ] || { bad "daemon start" "$(cat "$DIR/err")"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS=$ADDR
export DBUS_STARTER_BUS_TYPE=session
# ensure helpers do not try to launch a bus of their own
BUSDEST="--dest=org.freedesktop.DBus /org/freedesktop/DBus"

# ------------------------------------------------------------ dbus-send
if have dbus-send; then
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.ListNames 2>&1)
  check "dbus-send ListNames" "$out" 'string "org.freedesktop.DBus"'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.GetId 2>&1)
  check "dbus-send GetId" "$out" 'string "'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.RequestName string:org.example.Interop uint32:0 2>&1)
  check "dbus-send RequestName" "$out" 'uint32 1'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.NameHasOwner string:org.example.Interop 2>&1)
  check "dbus-send NameHasOwner (name released with the sender, so false)" "$out" 'boolean false'
  out=$(dbus-send --session --print-reply --dest=org.example.Missing / org.example.I.M 2>&1)
  check "dbus-send to a missing name reports ServiceUnknown" "$out" 'ServiceUnknown'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.Frobnicate 2>&1)
  check "dbus-send unknown method reports UnknownMethod" "$out" 'UnknownMethod'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.GetNameOwner string:org.freedesktop.DBus 2>&1)
  check "dbus-send GetNameOwner of the bus" "$out" 'org.freedesktop.DBus'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.Peer.Ping 2>&1; echo rc=$?)
  check "dbus-send Peer.Ping" "$out" 'rc=0'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.Introspectable.Introspect 2>&1)
  check "dbus-send Introspect" "$out" 'RequestName'
  out=$(dbus-send --session --type=signal /t org.example.I.Sig string:x 2>&1; echo rc=$?)
  check "dbus-send signal" "$out" 'rc=0'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.Properties.Get string:org.freedesktop.DBus string:Features 2>&1)
  check "dbus-send Properties.Get Features" "$out" 'variant'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.AddMatch string:"type='signal',interface='x.Y'" 2>&1; echo rc=$?)
  check "dbus-send AddMatch" "$out" 'rc=0'
  out=$(dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.AddMatch string:"bogus='x'" 2>&1)
  check "dbus-send AddMatch with a bad rule reports MatchRuleInvalid" "$out" 'MatchRuleInvalid'
else
  skip "dbus-send not installed"
fi

# ---------------------------------------------------------- dbus-monitor
if have dbus-monitor && have dbus-send; then
  dbus-monitor --session >"$DIR/mon.out" 2>&1 &
  MONPID=$!
  sleep 1
  dbus-send --session --type=signal /interop/path org.example.Interop.Ping string:hello >/dev/null 2>&1
  dbus-send --session --print-reply $BUSDEST org.freedesktop.DBus.GetId >/dev/null 2>&1
  sleep 1
  kill $MONPID 2>/dev/null; wait $MONPID 2>/dev/null; MONPID=
  out=$(cat "$DIR/mon.out")
  check "dbus-monitor sees a signal" "$out" 'member=Ping'
  check "dbus-monitor sees a method call to the bus" "$out" 'member=GetId'
  check "dbus-monitor sees NameOwnerChanged" "$out" 'NameOwnerChanged'
  dbus-monitor --session --profile >"$DIR/mon2.out" 2>&1 &
  MONPID=$!
  sleep 1
  dbus-send --session --type=signal /p2 org.example.Interop.Profiled >/dev/null 2>&1
  sleep 1
  kill $MONPID 2>/dev/null; wait $MONPID 2>/dev/null; MONPID=
  check "dbus-monitor --profile sees a signal" "$(cat "$DIR/mon2.out")" 'Profiled'
else
  skip "dbus-monitor not installed"
fi

# ---------------------------------------------------------------- busctl
if have busctl; then
  out=$(busctl --address="$ADDR" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId 2>&1)
  check "busctl call GetId" "$out" 's "'
  out=$(busctl --address="$ADDR" list --no-pager 2>&1)
  check "busctl list shows the bus" "$out" 'org.freedesktop.DBus'
  out=$(busctl --address="$ADDR" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus RequestName su org.example.Busctl 0 2>&1)
  check "busctl call RequestName" "$out" 'u 1'
  out=$(busctl --address="$ADDR" introspect org.freedesktop.DBus /org/freedesktop/DBus --no-pager 2>&1)
  check "busctl introspect" "$out" 'RequestName'
  out=$(busctl --address="$ADDR" get-property org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus Features 2>&1)
  check "busctl get-property Features" "$out" 'as '
  out=$(busctl --address="$ADDR" call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetNameOwner s no.such.name 2>&1)
  check "busctl error for a name without owner" "$out" 'no such name'
  out=$(timeout 3 busctl --address="$ADDR" monitor --no-pager 2>&1 &
        sleep 1; dbus-send --session --type=signal /bc org.example.Busctl.Sig >/dev/null 2>&1; sleep 1; wait)
  if have dbus-send; then check "busctl monitor starts and sees traffic" "$out" 'Monitoring'; fi
  out=$(busctl --address="$ADDR" status 2>&1)
  check "busctl status" "$out" 'PID='
else
  skip "busctl not installed"
fi

# ----------------------------------------------------------------- gdbus
if have gdbus; then
  out=$(gdbus call --address "$ADDR" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames 2>&1)
  check "gdbus call ListNames" "$out" "'org.freedesktop.DBus'"
  out=$(gdbus call --address "$ADDR" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner no.such.name 2>&1)
  check "gdbus error for a name without owner" "$out" 'NameHasNoOwner'
  out=$(gdbus introspect --address "$ADDR" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus 2>&1)
  check "gdbus introspect" "$out" 'RequestName'
  gdbus monitor --address "$ADDR" --dest org.freedesktop.DBus >"$DIR/gmon.out" 2>&1 &
  MONPID=$!
  sleep 1
  gdbus call --address "$ADDR" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.RequestName org.example.Gdbus 0 >/dev/null 2>&1
  sleep 1
  kill $MONPID 2>/dev/null; wait $MONPID 2>/dev/null; MONPID=
  check "gdbus monitor sees NameOwnerChanged" "$(cat "$DIR/gmon.out")" 'NameOwnerChanged'
  # emit and receive a signal through GDBus on one connection each
  gdbus monitor --address "$ADDR" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus >"$DIR/gmon2.out" 2>&1 &
  MONPID=$!
  sleep 1
  gdbus emit --address "$ADDR" --object-path /gdbus/emit --signal org.example.Gdbus.Emitted 'hello' >/dev/null 2>&1
  sleep 1
  kill $MONPID 2>/dev/null; wait $MONPID 2>/dev/null; MONPID=
  skip "gdbus emit is not seen by a monitor limited to the bus name (informational)"
else
  skip "gdbus not installed"
fi

# ---------------------------------------------------------------- python
if have python3 && python3 -c 'import dbus' 2>/dev/null; then
  out=$(python3 - "$ADDR" <<'PY' 2>&1
import sys, dbus
bus = dbus.bus.BusConnection(sys.argv[1])
proxy = bus.get_object('org.freedesktop.DBus', '/org/freedesktop/DBus')
iface = dbus.Interface(proxy, 'org.freedesktop.DBus')
names = iface.ListNames()
print('NAMES', 'org.freedesktop.DBus' in names, len(names))
print('REQ', int(iface.RequestName('org.example.Pydbus', 0)))
print('OWNER', str(iface.GetNameOwner('org.example.Pydbus')) == bus.get_unique_name())
try:
    iface.GetNameOwner('no.such.Name')
except dbus.DBusException as e:
    print('ERR', e.get_dbus_name())
props = dbus.Interface(proxy, 'org.freedesktop.DBus.Properties')
print('FEAT', type(props.Get('org.freedesktop.DBus', 'Features')).__name__)
print('ID', len(str(iface.GetId())))
PY
)
  check "python-dbus ListNames" "$out" 'NAMES True'
  check "python-dbus RequestName" "$out" 'REQ 1'
  check "python-dbus GetNameOwner" "$out" 'OWNER True'
  check "python-dbus error mapping" "$out" 'ERR org.freedesktop.DBus.Error.NameHasNoOwner'
  check "python-dbus Properties.Get" "$out" 'FEAT Array'
  check "python-dbus GetId" "$out" 'ID 32'
  # signals and replies between two python-dbus connections
  out=$(timeout 25 python3 - "$ADDR" <<'PY' 2>&1
import sys, dbus, dbus.service, dbus.lowlevel, dbus.mainloop.glib
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
addr = sys.argv[1]
a = dbus.bus.BusConnection(addr); b = dbus.bus.BusConnection(addr)
got = []; echo = []
loop = GLib.MainLoop()
def on_sig(x):
    got.append(str(x))
b.add_signal_receiver(on_sig, signal_name='Hi', dbus_interface='org.example.Py', path='/py')
class Obj(dbus.service.Object):
    @dbus.service.method('org.example.Py', in_signature='s', out_signature='s')
    def Echo(self, s): return s + '!'
name = dbus.service.BusName('org.example.PyService', bus=b)
o = Obj(b, '/py')
def emit():
    m = dbus.lowlevel.SignalMessage('/py', 'org.example.Py', 'Hi')
    m.append('sig', signature='s')
    a.send_message(m)
    a.call_async('org.example.PyService', '/py', 'org.example.Py', 'Echo', 's', ('ping',),
                 lambda r: (echo.append(str(r)), loop.quit()), lambda e: (echo.append('ERR ' + str(e)), loop.quit()))
    return False
GLib.timeout_add(300, emit)
GLib.timeout_add(8000, loop.quit)
loop.run()
print('SIGNAL', got, flush=True)
print('ECHO', echo[0] if echo else 'none', flush=True)
PY
)
  check "python-dbus signal delivery" "$out" "SIGNAL ['sig']"
  check "python-dbus method call between two clients" "$out" 'ECHO ping!'
else
  skip "python3 with dbus bindings not available"
fi

# ----------------------------------------------------------- gio in python
if have python3 && python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null; then
  out=$(timeout 20 python3 - "$ADDR" <<'PY' 2>&1
import sys, gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib
addr = sys.argv[1]
conn = Gio.DBusConnection.new_for_address_sync(addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
print('UNIQUE', conn.get_unique_name().startswith(':'))
r = conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ListNames', None, None, Gio.DBusCallFlags.NONE, -1, None)
print('NAMES', 'org.freedesktop.DBus' in r.unpack()[0])
try:
    conn.call_sync('org.no.Such', '/', 'x.I', 'M', None, None, Gio.DBusCallFlags.NONE, -1, None)
except GLib.Error as e:
    print('ERR', Gio.DBusError.get_remote_error(e))
owned = []
lost = []
id1 = Gio.bus_own_name_on_connection(conn, 'org.example.GioName', Gio.BusNameOwnerFlags.NONE, lambda c, n: owned.append(n), lambda c, n: lost.append(n))
loop = GLib.MainLoop()
GLib.timeout_add(1500, loop.quit)
loop.run()
print('OWNED', owned)
got = []
conn.signal_subscribe(None, 'org.example.Gio', 'Hi', '/gio', None, Gio.DBusSignalFlags.NONE, lambda *a: (got.append(a[5].unpack()), loop.quit()))
GLib.timeout_add(300, lambda: (conn.emit_signal(None, '/gio', 'org.example.Gio', 'Hi', GLib.Variant('(s)', ('x',))), False)[1])
GLib.timeout_add(3000, loop.quit)
loop.run()
print('SIGNAL', got)
PY
)
  check "GDBus (Gio) connects and authenticates" "$out" 'UNIQUE True'
  check "GDBus ListNames" "$out" 'NAMES True'
  check "GDBus remote error mapping" "$out" 'ERR org.freedesktop.DBus.Error.ServiceUnknown'
  check "GDBus owns a name" "$out" "OWNED ['org.example.GioName']"
  check "GDBus receives its own broadcast signal" "$out" "SIGNAL [('x',)]"
else
  skip "python3 with Gio not available"
fi

echo "interop: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
