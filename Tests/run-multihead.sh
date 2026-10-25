#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# CI entry point for the multi-monitor checks (gershwin-components issue
# #135): the headless unit suites of the Display pane and the menu bar, then
# the live checks on a private Xorg with the "dummy" video driver, which has
# 16 RandR outputs (Xvfb has one).  Prints a summary and exits non-zero when
# anything failed.
#
#   sh Tests/run-multihead.sh
#
# Environment:
#   MULTIHEAD_DISPLAY   display number to use, 200 or higher (default: the
#                       first free one from 200 up)
#   MULTIHEAD_REQUIRE   1 = a missing dummy driver is a failure (CI sets it
#                       where the package is installable); otherwise the live
#                       part is skipped with a message
#   MULTIHEAD_KEEP      directory for the logs (default: a fresh temp dir)
#   MULTIHEAD_NO_BUILD  1 = do not run gmake, use the existing builds
#
# It never uses an inherited DISPLAY and never touches a display below 200;
# the Xorg it starts is stopped on exit, nothing else is killed.  The tools
# run with a private HOME so no setting lands in a real home directory.

root=$(cd "$(dirname "$0")/.." && pwd)
harness=$root/Display/Tests/live-multihead.sh

# An inherited DISPLAY may be a user's desktop; every command below gets its
# own explicit one.
unset DISPLAY

passes=0
fails=0
skips=0
started=""

say() { echo "== $*"; }
ok() { passes=$((passes + 1)); echo "PASS: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }

[ -r "${GNUSTEP_MAKEFILES:-/System/Library/Makefiles}/GNUstep.sh" ] || {
  echo "FATAL: GNUstep.sh not found; install the Gershwin stack first" >&2
  exit 1
}
. "${GNUSTEP_MAKEFILES:-/System/Library/Makefiles}/GNUstep.sh"

# GNUstep.sh reads unset variables, so -u only starts here.
set -u

work=$(mktemp -d "${TMPDIR:-/tmp}/multihead.XXXXXX") || exit 1
logs=${MULTIHEAD_KEEP:-$work/logs}
mkdir -p "$logs" "$work/home"
HOME=$work/home
export HOME

cleanup() {
  if [ -n "$started" ]; then
    sh "$harness" stop "$started" >/dev/null 2>&1
  fi
  # Only the private temp dir made above.
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

display_in_use() {
  [ -e "/tmp/.X11-unix/X$1" ] || [ -e "/tmp/.X$1-lock" ] && return 0
  # Linux abstract sockets leave no file.
  grep -q "@/tmp/.X11-unix/X$1\$" /proc/net/unix 2>/dev/null
}

pick_display() {
  if [ -n "${MULTIHEAD_DISPLAY:-}" ]; then
    n=$MULTIHEAD_DISPLAY
    case $n in ''|*[!0-9]*) echo "FATAL: MULTIHEAD_DISPLAY must be a number" >&2; exit 2;; esac
    [ "$n" -ge 200 ] || { echo "FATAL: refusing display :$n, use 200 or higher" >&2; exit 2; }
    display_in_use "$n" && { echo "FATAL: display :$n is in use" >&2; exit 2; }
    echo "$n"; return
  fi
  n=200
  while [ $n -lt 400 ]; do
    display_in_use "$n" || { echo "$n"; return; }
    n=$((n + 1))
  done
  echo "FATAL: no free display from 200 to 399" >&2
  exit 2
}

# ---------------------------------------------------------------- unit tests

# run_tools DIR TOOL...: every tool must exit 0, pass at least one test and
# report no failed one (ObjectTesting prints "Failed test:").
run_tools() {
  dir=$1; shift
  for t in "$@"; do
    out=$logs/$(echo "$dir/$t" | tr / _).log
    ( cd "$dir" && ./obj/"$t" ) > "$out" 2>&1
    rc=$?
    np=$(grep -c '^Passed test:' "$out")
    nf=$(grep -c '^Failed test:' "$out")
    if [ $rc -eq 0 ] && [ "$nf" -eq 0 ] && [ "$np" -gt 0 ]; then
      ok "$t ($np tests)"
    else
      bad "$t (exit $rc, $np passed, $nf failed; log $out)"
      grep '^Failed test:' "$out" | head -5
    fi
  done
}

build() {  # build DIR [make args...]
  dir=$1; shift
  [ "${MULTIHEAD_NO_BUILD:-}" = 1 ] && return 0
  if ( cd "$dir" && gmake -j1 "$@" ) > "$logs/build-$(echo "$dir" | tr / _).log" 2>&1; then
    return 0
  fi
  bad "build of $dir (log $logs/build-$(echo "$dir" | tr / _).log)"
  tail -n 20 "$logs/build-$(echo "$dir" | tr / _).log"
  return 1
}

unit_tests() {
  say "unit tests (headless)"
  d=Display/Tests/Unit
  if build "$root/$d"; then
    run_tools "$root/$d" t_DisplayArrangement t_DisplayLayout t_DisplayConfiguration \
      t_DisplaySystemDefaults t_DisplayScaleHeuristic t_DisplayScaledResolution
  fi
  d=Menu/Tests/Unit
  if build "$root/$d" TEST_TOOL_NAME="t_PrimaryMonitor t_MenuBarGeometry t_PrimaryMonitorLive"; then
    # t_PrimaryMonitorLive without PRIMARY_MONITOR_LIVE_DISPLAY only logs a
    # skip; it runs for real in the live part below.
    run_tools "$root/$d" t_PrimaryMonitor t_MenuBarGeometry
  fi
}

# ---------------------------------------------------------------- live tests

driver_installed() {
  for d in /usr/lib/xorg/modules/drivers /usr/lib64/xorg/modules/drivers \
           /usr/lib/x86_64-linux-gnu/xorg/modules/drivers \
           /usr/local/lib/xorg/modules/drivers /usr/X11R6/lib/modules/drivers \
           /usr/lib/xorg/modules/drivers; do
    [ -e "$d/dummy_drv.so" ] && return 0
  done
  return 1
}

start_server() {
  sh "$harness" start "$num" "$work/xorg" > "$logs/xorg-start-$num.log" 2>&1 || {
    bad "dummy Xorg did not start on :$num"
    cat "$logs/xorg-start-$num.log"
    return 1
  }
  started=$num
}

stop_server() {
  [ -n "$started" ] || return 0
  sh "$harness" stop "$started" >/dev/null 2>&1
  # The next start refuses while the old socket or lock is still there.
  i=0
  while [ $i -lt 50 ] && display_in_use "$started"; do sleep 0.2; i=$((i + 1)); done
  started=""
}

# Each suite gets a fresh server: they reconfigure the outputs.
fresh_server() {
  stop_server
  cp "$work"/xorg/*.log "$logs"/ 2>/dev/null
  rm -rf "$work/xorg"
  start_server
}

xr() { DISPLAY=:$num xrandr "$@"; }

live_tests() {
  say "live: Display pane layout on 3 outputs"
  build "$root/Display/Tests/Live" && fresh_server &&
    # "run" starts from DUMMY0 alone with DUMMY1 and DUMMY2 plugged in.
    sh "$harness" plug "$num" DUMMY1 > /dev/null 2>&1 &&
    sh "$harness" plug "$num" DUMMY2 > /dev/null 2>&1 &&
    if sh "$harness" run "$num" > "$logs/live-multihead.log" 2>&1; then
      ok "live-multihead.sh ($(tail -n 1 "$logs/live-multihead.log"))"
    else
      bad "live-multihead.sh (log $logs/live-multihead.log)"
      grep '^FAIL' "$logs/live-multihead.log" | head
    fi

  say "live: menu bar primary monitor over one RandR connection"
  if fresh_server; then
    sh "$harness" plug "$num" DUMMY1 > /dev/null 2>&1
    # t_PrimaryMonitorLive wants DUMMY1 connected and DUMMY0 alone on 1280x800.
    out=$logs/t_PrimaryMonitorLive.log
    ( cd "$root/Menu/Tests/Unit" && PRIMARY_MONITOR_LIVE_DISPLAY=:$num ./obj/t_PrimaryMonitorLive ) > "$out" 2>&1
    rc=$?
    np=$(grep -c '^Passed test:' "$out"); nf=$(grep -c '^Failed test:' "$out")
    if [ $rc -eq 0 ] && [ "$nf" -eq 0 ] && [ "$np" -gt 0 ]; then
      ok "t_PrimaryMonitorLive ($np tests)"
    else
      bad "t_PrimaryMonitorLive (exit $rc, $np passed, $nf failed; log $out)"
      grep '^Failed test:' "$out" | head -5
    fi
  fi

  say "live: displayconfig saves and re-applies a layout"
  if build "$root/DisplayConfig" && fresh_server; then
    tool=$root/DisplayConfig/obj/displayconfig
    live=$root/Display/Tests/Live/obj/display-live
    sh "$harness" plug "$num" DUMMY1 > /dev/null 2>&1
    DISPLAY=:$num "$live" enable DUMMY1 > /dev/null 2>&1
    DISPLAY=:$num "$tool" save > "$logs/displayconfig-save.log" 2>&1 &&
      ok "displayconfig save" || bad "displayconfig save (log $logs/displayconfig-save.log)"
    DISPLAY=:$num "$tool" print --json 2>&1 | grep -q '"saved"' &&
      ok "displayconfig print reports the layout as saved" ||
      bad "displayconfig print reports the layout as saved"
    DISPLAY=:$num "$tool" apply 2>&1 | grep -q '^unchanged' &&
      ok "displayconfig apply on an unchanged server changes nothing" ||
      bad "displayconfig apply on an unchanged server changes nothing"
  fi
}

# ---------------------------------------------------------------------- main

echo "gershwin-components multi-monitor checks, $(uname -s)"
unit_tests

if ! command -v xrandr >/dev/null 2>&1; then
  if [ "${MULTIHEAD_REQUIRE:-}" = 1 ]; then bad "xrandr is not installed"
  else skips=$((skips + 1)); echo "SKIP: live checks, xrandr is not installed"; fi
elif ! driver_installed; then
  if [ "${MULTIHEAD_REQUIRE:-}" = 1 ]; then
    bad "the Xorg dummy video driver is not installed (xserver-xorg-video-dummy / xf86-video-dummy)"
  else
    skips=$((skips + 1))
    echo "SKIP: live checks, the Xorg dummy video driver is not installed"
  fi
else
  num=$(pick_display) || exit 2
  echo "private Xorg on :$num"
  live_tests
  stop_server
fi

echo
echo "multihead summary: $passes passed, $fails failed, $skips skipped"
[ $fails -eq 0 ]
