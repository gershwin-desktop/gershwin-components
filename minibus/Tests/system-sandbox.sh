#!/bin/sh
# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause
#
# Real system services (avahi-daemon, upowerd, NetworkManager) against a
# system bus in a sandbox, so the host's own system bus is never touched.
# Linux only. Run as root, compare the two directories afterwards:
#
#   sudo unshare -m -n sh Tests/system-sandbox.sh real    /some/dir/real
#   sudo unshare -m -n sh Tests/system-sandbox.sh minibus /some/dir/minibus
#
# Runs as root inside `unshare -m -n`: a private mount and network namespace.
# Gives the services a private /run (and private NetworkManager state), starts
# the bus under test on /run/dbus/system_bus_socket, starts real system
# services against it and queries them. Nothing here is visible outside the
# namespaces; leaving the shell undoes all mounts.
#   inside.sh minibus|real OUTDIR
set -u
MODE=$1
OUT=$2
MB=${MINIBUS_BIN:-$(cd "$(dirname "$0")/.." && pwd)/obj/minibus}
mkdir -p "$OUT"
log() { echo "== $*" >>"$OUT/steps.txt"; }

# never let a mount leak to the host
mount --make-rprivate /

# keep the host's udev database readable for upowerd, then cover /run
KEEP=$(mktemp -d)
mount --bind /run/udev "$KEEP"
mount -t tmpfs -o mode=755 tmpfs /run
mkdir -p /run/udev /run/dbus /run/avahi-daemon /run/NetworkManager /run/user
mount --bind "$KEEP" /run/udev
mount -o remount,bind,ro /run/udev
chown messagebus:messagebus /run/dbus 2>/dev/null
chown avahi:avahi /run/avahi-daemon 2>/dev/null

# NetworkManager and upower keep state in /var/lib; give them empty copies
for d in /var/lib/NetworkManager /var/lib/upower; do
  [ -d "$d" ] && mount -t tmpfs tmpfs "$d"
done
# resolv.conf must not be touched on the host
cp /etc/resolv.conf "$KEEP.resolv" 2>/dev/null && mount --bind "$KEEP.resolv" /etc/resolv.conf

ip link set lo up
log "namespace ready: $(ip -o link | wc -l) interface(s)"

if [ "$MODE" = minibus ]; then
  "$MB" --system --nofork --verbose >"$OUT/bus.log" 2>&1 &
else
  dbus-daemon --system --nofork --nopidfile >"$OUT/bus.log" 2>&1 &
fi
BUS=$!
for i in $(seq 1 50); do [ -S /run/dbus/system_bus_socket ] && break; sleep 0.1; done
log "bus $MODE pid $BUS socket $(stat -c %a /run/dbus/system_bus_socket)"

avahi-daemon --no-chroot --no-drop-root -s >"$OUT/avahi.log" 2>&1 &
AV=$!
/usr/libexec/upowerd -v >"$OUT/upower.log" 2>&1 &
UP=$!
NetworkManager --no-daemon --log-level=INFO >"$OUT/nm.log" 2>&1 &
NM=$!
sleep 4

B="busctl --system --no-pager"
{
  echo "--- ListNames (well-known)"; $B list 2>&1 | awk 'NR==1 || $1 !~ /^:/'
  echo "--- Avahi"; $B call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetVersionString 2>&1
  $B call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState 2>&1
  $B call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetHostName 2>&1
  echo "--- UPower"; $B call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower EnumerateDevices 2>&1
  $B get-property org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower DaemonVersion 2>&1
  $B get-property org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower OnBattery 2>&1
  $B call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower GetDisplayDevice 2>&1
  echo "--- NetworkManager"; $B get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Version 2>&1
  $B call org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager GetDevices 2>&1
  $B get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager State 2>&1
  echo "--- nmcli"; nmcli -t general status 2>&1; nmcli -t device 2>&1
  echo "--- gdbus introspect"; gdbus introspect --system -d org.freedesktop.UPower -o /org/freedesktop/UPower 2>&1 | head -5
  echo "--- tree"; $B tree org.freedesktop.NetworkManager 2>&1 | head -20
} >"$OUT/queries.txt" 2>&1

# Properties changed signals reach a watcher: let avahi publish and browse a service
timeout 6 dbus-monitor --system "type='signal',sender='org.freedesktop.Avahi'" >"$OUT/avahi-signals.txt" 2>&1 &
MON=$!
sleep 0.5
timeout 4 avahi-browse -a -t >"$OUT/avahi-browse.txt" 2>&1
avahi-publish -s minibus-test _test._tcp 4242 >"$OUT/avahi-publish.txt" 2>&1 &
PUB=$!
sleep 2
timeout 3 avahi-browse -t -r _test._tcp >>"$OUT/avahi-browse.txt" 2>&1
kill $PUB 2>/dev/null
wait $MON 2>/dev/null

# a service restart: the name must move to the new instance
kill $UP; wait $UP 2>/dev/null
/usr/libexec/upowerd -v >>"$OUT/upower.log" 2>&1 &
UP=$!
sleep 2
$B call org.freedesktop.UPower /org/freedesktop/UPower org.freedesktop.UPower EnumerateDevices >"$OUT/upower-restart.txt" 2>&1

kill $NM $AV $UP 2>/dev/null
sleep 2
kill -9 $NM $AV $UP 2>/dev/null
kill $BUS; wait $BUS 2>/dev/null
log "bus exit status $?"
log "done"
