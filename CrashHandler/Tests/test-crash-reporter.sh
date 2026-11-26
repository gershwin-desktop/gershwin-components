#!/bin/sh
# Crashes CrashTestApp on purpose in every way the bundle knows and checks the exit status, that exactly one non-empty
# report appears, and what the report and stderr contain.  The bundle is loaded from the build directory through the
# GSAppKitUserBundles default, so nothing has to be installed.
# Usage: test-crash-reporter.sh [DISPLAY]   (needs a private X display, never the desktop's own)
here=$(cd "$(dirname "$0")" && pwd)
display=${1:?usage: test-crash-reporter.sh DISPLAY}
case $display in :0|:0.0) echo "refusing the desktop's display"; exit 2;; esac
exe=${CRASH_TEST_APP:-$here/CrashTestApp.app/CrashTestApp}
bundle=${CRASH_REPORTER_BUNDLE:-$here/../CrashHandler.bundle}
dir=$(mktemp -d)
fail=0

check() {
  kind=$1 want_status=$2 want_text=$3
  mkdir "$dir/$kind"
  DISPLAY=$display GSCrashHandlerDir=$dir/$kind GSCrashHandlerTest=$kind GNUSTEP_CONFIG_FILE=$dir/gnustep.conf \
    timeout 60 "$exe" -GSTheme Eau -GSAppKitUserBundles "(\"$bundle\")" >"$dir/$kind.err" 2>&1
  status=$?
  count=$(ls "$dir/$kind" | wc -l)
  report=$(ls "$dir/$kind"/CrashTestApp-crash-*.txt 2>/dev/null | head -n 1)
  [ "$status" = "$want_status" ] || { echo "FAIL $kind: exit status $status, wanted $want_status"; fail=1; }
  [ "$count" = 1 ] || { echo "FAIL $kind: $count files in the report directory, wanted 1"; fail=1; }
  [ -n "$report" ] && [ -s "$report" ] || { echo "FAIL $kind: no non-empty report"; fail=1; return; }
  for text in "$want_text" "deliberate crash test: $kind" "last user actions" "executable:" "key window: Crash Test"; do
    grep -q -- "$text" "$report" || { echo "FAIL $kind: report lacks '$text'"; fail=1; }
  done
  grep -q -- "$want_text" "$dir/$kind.err" || { echo "FAIL $kind: stderr lacks '$want_text'"; fail=1; }
  echo "ok   $kind (status $status): $report"
}

printf 'GNUSTEP_USER_DEFAULTS_DIR=%s\n' "$dir/defaults" >"$dir/gnustep.conf"
check segv 139 "SIGSEGV"
check abort 134 "SIGABRT"
check stackoverflow 139 "SIGSEGV"
check thread-segv 139 "secondary thread"
check nsexception 1 "reason: deliberate exception"

# A run that is merely stopped must leave no file behind (the old reporter left empty ones).
for sig in TERM KILL; do
  mkdir "$dir/idle-$sig"
  DISPLAY=$display GSCrashHandlerDir=$dir/idle-$sig GNUSTEP_CONFIG_FILE=$dir/gnustep.conf \
    timeout -s $sig 4 "$exe" -GSTheme Eau -GSAppKitUserBundles "(\"$bundle\")" >/dev/null 2>&1
  if [ -n "$(ls "$dir/idle-$sig")" ]; then echo "FAIL idle $sig: left $(ls "$dir/idle-$sig")"; fail=1; else echo "ok   idle $sig leaves no file"; fi
done
echo "reports kept in $dir"
exit $fail
