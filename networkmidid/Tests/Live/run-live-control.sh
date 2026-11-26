#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Starts the uninstalled networkmidid with a private defaults directory, runs
# t_LiveControl against it, stops it.  Run from networkmidid/ after "gmake" in
# networkmidid/ and in Tests/Live/.  Uses UDP ports 25010-25041 on this machine
# and announces two sessions on the local network while it runs.
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
OUT=${1:-$HERE/results}
set +u; . /System/Library/Makefiles/GNUstep.sh
rm -rf "$OUT"; mkdir -p "$OUT/defaults"
if pgrep -u "$(id -u)" -x networkmidid >/dev/null; then
  echo "a networkmidid of this user is running; the test needs the control name"; exit 2
fi
grep -v -e '^GNUSTEP_USER_DEFAULTS_DIR' -e '^GNUSTEP_FILESYSTEM_LAYOUT' \
  /etc/GNUstep/GNUstep.conf > "$OUT/GNUstep.conf"
echo "GNUSTEP_USER_DEFAULTS_DIR=$OUT/defaults" >> "$OUT/GNUstep.conf"
GNUSTEP_CONFIG_FILE=$OUT/GNUstep.conf
LD_LIBRARY_PATH=$TOP/../Libraries/MIDINetworkBackend/obj:$LD_LIBRARY_PATH
export GNUSTEP_CONFIG_FILE LD_LIBRARY_PATH
"$TOP/obj/networkmidid" > "$OUT/networkmidid.log" 2>&1 &
PID=$!
sleep 1.5
"$HERE/obj/t_LiveControl" > "$OUT/t_LiveControl.log" 2>&1
kill $PID; wait $PID 2>/dev/null
grep -E "Passed test|Failed test|Uncaught" "$OUT/t_LiveControl.log"
echo "passed: $(grep -c 'Passed test' "$OUT/t_LiveControl.log")" \
  "failed: $(grep -c 'Failed test' "$OUT/t_LiveControl.log")"
! grep -q -E "Failed test|Uncaught" "$OUT/t_LiveControl.log"
