#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# Interoperability test of gwmidid against rtpmidid on this machine, over
# loopback, through the real ALSA sequencer.
#
#   RTPMIDID=/path/to/rtpmidid sh Tests/Interop/rtpmidid-interop.sh [results-dir]
#
# Run from the gwmidid directory after "gmake".  rtpmidid is only the test
# peer and is never needed by gwmidid itself; it is not packaged by Debian,
# build it from source (cmake, libasound2-dev, libavahi-client-dev,
# libfmt-dev).  Needs aseqdump, aplaymidi, aconnect (alsa-utils), python3,
# a running avahi-daemon (or mDNSResponder), and read/write access to
# /dev/snd/seq (group audio; the snd-seq module is loaded on first open).
#
# gwmidid runs with its own GNUstep defaults directory inside the results
# directory, so the user's real configuration is neither read nor changed.
# Both daemons announce their sessions on the local network while the test
# runs (gwmidid-interop, rtpmidid-peer).
#
# Scenarios:
#   A  gwmidid invites rtpmidid, found by its mDNS name
#   B  rtpmidid invites gwmidid
#   in both: clock sync and latency, note on/off, control change, pitch bend
#   and a 2000-byte sysex in both directions, then a clean disconnect
#   C  rtpmidid is killed while connected: gwmidid must notice and clean up
#   D  gwmidid is stopped while connected: rtpmidid must see the BY
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../.." && pwd)
OUT=${1:-$TOP/Tests/Interop/results}
GWMIDID=${GWMIDID:-$TOP/obj/gwmidid}
GWMIDICTL=${GWMIDICTL:-$TOP/obj/gwmidictl}
RTPMIDID=${RTPMIDID:?set RTPMIDID to the rtpmidid binary}
SESSION=gwmidid-interop
PORT=25004
PEER=rtpmidid-peer
PEERPORT=15004

FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

for t in aseqdump aplaymidi aconnect python3; do
  command -v $t >/dev/null || { echo "missing $t"; exit 2; }
done
[ -x "$GWMIDID" ] && [ -x "$GWMIDICTL" ] || { echo "build gwmidid first (gmake)"; exit 2; }
[ -r /dev/snd/seq ] && [ -w /dev/snd/seq ] || {
  echo "no access to /dev/snd/seq: load snd-seq (sudo modprobe snd-seq) and join group audio"
  exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT/defaults"
set +u; . /System/Library/Makefiles/GNUstep.sh; set -u

# Private defaults: a copy of the system GNUstep.conf pointing the user
# defaults elsewhere.
grep -v -e '^GNUSTEP_USER_DEFAULTS_DIR' -e '^GNUSTEP_FILESYSTEM_LAYOUT' \
  /etc/GNUstep/GNUstep.conf > "$OUT/GNUstep.conf"
echo "GNUSTEP_USER_DEFAULTS_DIR=$OUT/defaults" >> "$OUT/GNUstep.conf"
GNUSTEP_CONFIG_FILE=$OUT/GNUstep.conf
export GNUSTEP_CONFIG_FILE
# The library the uninstalled gwmidid was linked against
MNB=$TOP/../Libraries/MIDINetworkBackend/obj
[ -d "$MNB" ] && { LD_LIBRARY_PATH=$MNB:${LD_LIBRARY_PATH:-}; export LD_LIBRARY_PATH; }
if pgrep -u "$(id -u)" -x gwmidid >/dev/null; then
  echo "a gwmidid of this user is running; the test needs the control name"; exit 2
fi

cat > "$OUT/rtpmidid.ini" <<EOF
[general]
alsa_name=$PEER
control=$OUT/rtpmidid.sock
log_level=debug
[rtpmidi_announce]
name=$PEER
port=$PEERPORT
[rtpmidi_discover]
enabled=false
[alsa_hw_auto_export]
type=none
EOF

python3 -I "$HERE/midi_helper.py" write "$OUT/test.mid"

GWPID=
RTPID=
DUMPPID=
KEEPPID=
cleanup() {
  [ -n "$DUMPPID" ] && kill $DUMPPID 2>/dev/null
  [ -n "$KEEPPID" ] && kill $KEEPPID 2>/dev/null
  [ -n "$GWPID" ] && kill $GWPID 2>/dev/null
  [ -n "$RTPID" ] && kill $RTPID 2>/dev/null
}
trap cleanup EXIT INT TERM

start_rtpmidid() {
  "$RTPMIDID" --ini "$OUT/rtpmidid.ini" >> "$OUT/rtpmidid.log" 2>&1 &
  RTPID=$!
  sleep 1.5
}

start_gwmidid() {
  "$GWMIDID" >> "$OUT/gwmidid.log" 2>&1 &
  GWPID=$!
  sleep 1.5
}

status() { "$GWMIDICTL" status; }

rtpctl() {
  python3 -I - "$OUT/rtpmidid.sock" "$@" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
# rtpmidid wants the port as a number, not a string
params = [int(a) if a.isdigit() else a for a in sys.argv[3:]]
s.sendall(json.dumps({"method": sys.argv[2], "params": params}).encode() + b"\n")
print(s.recv(65536).decode())
EOF
}

# alsa_port <client name> <port name>: prints client:port
alsa_port() {
  aconnect -l | awk -v c="$1" -v p="$2" '
    /^client / { split($0, a, "'"'"'"); cn = a[2]; sub(/:$/, "", $2); id = $2 }
    /^    [0-9]+ / { split($0, b, "'"'"'"); pn = b[2]; sub(/ +$/, "", pn);
      if (cn == c && pn == p) { print id ":" $1; exit } }'
}

wait_for() {  # wait_for <seconds> <command...>
  n=$1; shift
  while [ "$n" -gt 0 ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1; n=$((n - 1))
  done
  return 1
}

connected() { status | grep -q '^  participant .* state=connected'; }
no_participants() { ! status | grep -q '^  participant '; }

# exchange <label> <our port> <peer port>
exchange() {
  label=$1; ours=$2; theirs=$3
  aseqdump -p "$theirs" > "$OUT/$label-gw-to-rtp.txt" 2>&1 &
  DUMPPID=$!
  sleep 0.5
  aplaymidi -p "$ours" "$OUT/test.mid"
  sleep 1.5
  kill $DUMPPID; DUMPPID=
  echo "$label gwmidid -> rtpmidid:"
  if python3 -I "$HERE/midi_helper.py" check "$OUT/$label-gw-to-rtp.txt"; then
    pass "$label: MIDI from gwmidid arrives at rtpmidid"
  else
    fail "$label: MIDI from gwmidid arrives at rtpmidid"
  fi

  aseqdump -p "$ours" > "$OUT/$label-rtp-to-gw.txt" 2>&1 &
  DUMPPID=$!
  sleep 0.5
  aplaymidi -p "$theirs" "$OUT/test.mid"
  sleep 1.5
  kill $DUMPPID; DUMPPID=
  echo "$label rtpmidid -> gwmidid:"
  if python3 -I "$HERE/midi_helper.py" check "$OUT/$label-rtp-to-gw.txt"; then
    pass "$label: MIDI from rtpmidid arrives at gwmidid"
  else
    fail "$label: MIDI from rtpmidid arrives at gwmidid"
  fi
}

latency() {
  status | sed -n 's/^  participant .* latency-ms=\([0-9.]*\).*/\1/p' | head -1
}

echo "== start"
start_rtpmidid
start_gwmidid
"$GWMIDICTL" add "$SESSION" $PORT && "$GWMIDICTL" enable "$SESSION"
OURPORT=$(alsa_port "Network MIDI" "$SESSION")
[ -n "$OURPORT" ] && pass "gwmidid session has MIDI port $OURPORT" \
  || fail "gwmidid session has a MIDI port"

echo "== A: gwmidid invites rtpmidid"
if wait_for 15 sh -c "\"$GWMIDICTL\" status | grep -q '^host \"$PEER\" address=[0-9]'"; then
  pass "A: rtpmidid's announcement is discovered"
else
  fail "A: rtpmidid's announcement is discovered"
fi
wait_for 10 "$GWMIDICTL" connect "$SESSION" "$PEER"
if wait_for 10 connected; then
  pass "A: session connected, clock synced, latency $(latency) ms"
else
  fail "A: session connected"
fi
THEIRS=$(alsa_port "$PEER" "$SESSION")
[ -n "$THEIRS" ] && exchange A "$OURPORT" "$THEIRS" || fail "A: rtpmidid port for $SESSION"
"$GWMIDICTL" disconnect "$SESSION" "$PEER"
sleep 1
if no_participants && grep -q 'Disconnect from '"$SESSION" "$OUT/rtpmidid.log"; then
  pass "A: clean disconnect seen by both sides"
else
  fail "A: clean disconnect seen by both sides"
fi

echo "== B: rtpmidid invites gwmidid"
rtpctl connect gwmidid-B 127.0.0.1 $PORT > "$OUT/B-connect.json"
sleep 1
THEIRS=$(alsa_port "$PEER" gwmidid-B)
if [ -n "$THEIRS" ]; then
  # rtpmidid only connects once something uses its port, and disconnects
  # when nothing does any more, so this listener stays until C.
  aseqdump -p "$THEIRS" > /dev/null 2>&1 &
  KEEPPID=$!
  if wait_for 10 connected; then
    pass "B: rtpmidid joined, clock synced, latency $(latency) ms"
  else
    fail "B: rtpmidid joined"
  fi
  exchange B "$OURPORT" "$THEIRS"
else
  fail "B: rtpmidid created its port"
fi

echo "== C: rtpmidid disappears while connected"
if connected; then
  T0=$(date +%s)
  kill -9 $RTPID; RTPID=
  if wait_for 60 no_participants; then
    pass "C: gwmidid dropped the vanished peer after $(( $(date +%s) - T0 )) s"
    kill $KEEPPID 2>/dev/null; KEEPPID=
  else
    fail "C: gwmidid dropped the vanished peer within 60 s"
  fi
else
  fail "C: needs the session of B"
fi

echo "== D: gwmidid stops while connected"
[ -n "$RTPID" ] && { kill $RTPID; wait $RTPID 2>/dev/null; RTPID=; }
start_rtpmidid
wait_for 15 sh -c "\"$GWMIDICTL\" status | grep -q '^host \"$PEER\" address=[0-9]'"
wait_for 10 "$GWMIDICTL" connect "$SESSION" "$PEER"
if wait_for 10 connected; then
  N=$(grep -c 'Parse BY' "$OUT/rtpmidid.log")
  kill $GWPID; wait $GWPID 2>/dev/null; GWPID=
  sleep 1
  if [ "$(grep -c 'Parse BY' "$OUT/rtpmidid.log")" -ge $((N + 2)) ]; then
    pass "D: rtpmidid got BY on both ports when gwmidid stopped"
  else
    fail "D: rtpmidid got BY on both ports when gwmidid stopped"
  fi
else
  fail "D: reconnect for the shutdown test"
fi

echo "== $FAILS failure(s); logs in $OUT"
[ $FAILS -eq 0 ]
