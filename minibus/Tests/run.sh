#!/bin/sh
# Copyright (c) 2026 Simon Peter
# SPDX-License-Identifier: BSD-2-Clause
#
# Build and run the minibus conformance suite.
#
#   run.sh [t_Tool ...]            default: every t_* tool plus interop.sh
#   MINIBUS_TEST_DAEMON=real|minibus   daemon under test (default minibus)
#   MINIBUS_BIN=/path/to/minibus       binary for the minibus mode
#                                      (default ../obj/minibus next to Tests)
#   MINIBUS_TEST_NOBUILD=1             do not run gmake first
#   MINIBUS_TEST_SERIAL=1              run the tools one after the other
#   MINIBUS_TEST_CLIENTS / _FLOOD_MB   size of the t_Scale crowd and flood
#
# Works from any directory. Exit status is non-zero when any check failed.

HERE=$(cd "$(dirname "$0")" && pwd)
MINIBUS_TEST_DAEMON=${MINIBUS_TEST_DAEMON:-minibus}
export MINIBUS_TEST_DAEMON
MINIBUS_BIN=${MINIBUS_BIN:-$HERE/../obj/minibus}
case "$MINIBUS_BIN" in /*) ;; *) MINIBUS_BIN=$(pwd)/$MINIBUS_BIN ;; esac
export MINIBUS_BIN
MINIBUS_TESTS_DIR=$HERE
export MINIBUS_TESTS_DIR

if [ "$MINIBUS_TEST_DAEMON" = minibus ] && [ ! -x "$MINIBUS_BIN" ]; then
  echo "SKIP: minibus binary $MINIBUS_BIN not found (build it with gmake in minibus/, or set MINIBUS_BIN)"
  echo "      to check the suite itself: MINIBUS_TEST_DAEMON=real $0"
  exit 0
fi

if [ -z "$GNUSTEP_MAKEFILES" ]; then
  [ -f /System/Library/Makefiles/GNUstep.sh ] && . /System/Library/Makefiles/GNUstep.sh
fi

if [ -z "$MINIBUS_TEST_NOBUILD" ]; then
  ( cd "$HERE" && gmake >"$HERE/obj.build.log" 2>&1 ) || {
    echo "build failed, see $HERE/obj.build.log"; tail -20 "$HERE/obj.build.log"; exit 1; }
  rm -f "$HERE/obj.build.log"
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/minibus-tests.XXXXXX") || exit 1
trap 'rm -rf "$OUT"' EXIT INT TERM

if [ $# -gt 0 ]; then TOOLS="$*"; else
  TOOLS=$(cd "$HERE/obj" 2>/dev/null && for f in t_*; do [ -f "$f" ] && [ -x "$f" ] && echo "$f"; done)
  RUN_INTEROP=1
fi

echo "== daemon: $MINIBUS_TEST_DAEMON$( [ "$MINIBUS_TEST_DAEMON" = minibus ] && echo " ($MINIBUS_BIN)" )"
for t in $TOOLS; do
  if [ -n "$MINIBUS_TEST_SERIAL" ]; then
    "$HERE/obj/$t" >"$OUT/$t.log" 2>&1; echo $? >"$OUT/$t.rc"
  else
    ( "$HERE/obj/$t" >"$OUT/$t.log" 2>&1; echo $? >"$OUT/$t.rc" ) &
  fi
done
if [ -n "$RUN_INTEROP" ]; then
  if [ -n "$MINIBUS_TEST_SERIAL" ]; then
    sh "$HERE/interop.sh" >"$OUT/interop.log" 2>&1; echo $? >"$OUT/interop.rc"
  else
    ( sh "$HERE/interop.sh" >"$OUT/interop.log" 2>&1; echo $? >"$OUT/interop.rc" ) &
  fi
fi
wait

FAILED=0; TOTAL_P=0; TOTAL_F=0
for log in "$OUT"/*.log; do
  name=$(basename "$log" .log)
  rc=$(cat "$OUT/$name.rc" 2>/dev/null || echo 99)
  if [ "$name" = interop ]; then
    p=$(grep -c '^PASS ' "$log"); f=$(grep -c '^FAIL ' "$log"); s=$(grep -c '^SKIP ' "$log")
  else
    p=$(grep -c '^Passed test' "$log"); f=$(grep -c '^Failed test' "$log"); s=$(grep -c '^SKIP:' "$log")
  fi
  status=ok
  if [ "$s" -gt 0 ] && [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then status=skipped
  elif [ "$f" -gt 0 ] || [ "$rc" -ne 0 ] || [ "$p" -eq 0 ]; then status=FAILED; FAILED=$((FAILED + 1)); fi
  TOTAL_P=$((TOTAL_P + p)); TOTAL_F=$((TOTAL_F + f))
  printf '%-16s %5d passed %4d failed  exit %-3s %s\n' "$name" "$p" "$f" "$rc" "$status"
  if [ "$status" = FAILED ]; then
    grep -E '^(Failed test|FAIL |WATCHDOG|Uncaught)' "$log" | head -15 | sed 's/^/    /'
    [ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && tail -5 "$log" | sed 's/^/    /'
  fi
done
echo "== total: $TOTAL_P passed, $TOTAL_F failed, $FAILED tool(s) failed"
[ "$FAILED" -eq 0 ]
