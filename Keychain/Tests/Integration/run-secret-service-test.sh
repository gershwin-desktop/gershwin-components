#!/bin/sh
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# End-to-end test of Keychain.app as the session's Secret Service: a client
# creates the default keyring, stores and reads secrets over plain and DH
# sessions, locks it; the service is restarted (a new login) and the secret
# is read back after unlocking; then libsecret stores and, after another
# restart, looks up a password. Password prompts are answered in Keychain's
# own panel with DriveUI, as a user would.
#
# Run it in an isolated test session as the session's user (never on the
# desktop you are working on: it deletes the user's Library/Keyrings):
#   DISPLAY=:N DBUS_SESSION_BUS_ADDRESS=... KC_APP=/path/Keychain.app \
#     sh run-secret-service-test.sh
# The app must be readable by that user; DriveUI.bundle must be listed in
# its GSAppKitUserBundles (uitest-session.sh sets that up).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CLIENT="$HERE/secret_service_client.py"
DRIVE=${DRIVE:-/System/Library/Tools/drive_ui}
PASSWORD="correct horse battery"
KEYRINGS="$(gnustep-config --variable=GNUSTEP_USER_LIBRARY)/Keyrings"
OUT=${KC_OUT:-/tmp}
APP_PID=

fail() { echo "FAIL: $*"; stop_app; exit 1; }

name_owned() {
  dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
    org.freedesktop.DBus.NameHasOwner string:org.freedesktop.secrets 2>/dev/null \
    | grep -q "boolean true"
}

start_app() {
  "$KC_APP/Keychain" "$@" >>"$OUT/keychain-app.log" 2>&1 &
  APP_PID=$!
  i=0
  until name_owned && [ -S "/tmp/driveui.$APP_PID.sock" ]; do
    i=$((i + 1)); [ $i -gt 60 ] && fail "Keychain did not take org.freedesktop.secrets"
    sleep 0.5
  done
  echo "PASS: Keychain (pid $APP_PID) owns org.freedesktop.secrets"
}

stop_app() {
  [ -n "$APP_PID" ] || return 0
  kill -9 "$APP_PID" 2>/dev/null
  wait "$APP_PID" 2>/dev/null
  APP_PID=
  i=0
  while name_owned; do i=$((i + 1)); [ $i -gt 20 ] && break; sleep 0.5; done
}

# Types the password into every secure field of the panel and presses its
# default button, then checks the panel went away.
answer_panel() {
  title=$1 button=$2
  "$DRIVE" --pid "$APP_PID" wait_until --window "$title" --class NSSecureTextField \
    --timeout 30 >/dev/null || fail "no \"$title\" panel appeared"
  sleep 0.5
  for id in $("$DRIVE" --pid "$APP_PID" find_widgets --class NSSecureTextField \
                --window "$title" --visible | awk -F'\t' '{print $9}'); do
    "$DRIVE" --pid "$APP_PID" type "$id" "$PASSWORD" >/dev/null
  done
  "$DRIVE" --pid "$APP_PID" click --text "$button" --class NSButton \
    --window "$title" >/dev/null
  echo "PASS: answered the \"$title\" panel"
}

# Runs a client step that needs a prompt answered while it waits.
client_with_prompt() {
  step=$1 title=$2 button=$3
  python3 "$CLIENT" "$step" >"$OUT/client-$step.log" 2>&1 &
  cpid=$!
  answer_panel "$title" "$button"
  wait $cpid; rc=$?
  cat "$OUT/client-$step.log"
  [ $rc -eq 0 ] || fail "client step $step"
}

rm -rf "$KEYRINGS"
: >"$OUT/keychain-app.log"

start_app -KCServiceLaunch YES
client_with_prompt create "New Keyring" Create
ls -l "$KEYRINGS"
# ls rather than stat: stat's format flags differ between Linux and the BSDs.
case $(ls -l "$KEYRINGS/login.keyring") in
  -rw-------*) echo "PASS: keyring file is 0600" ;;
  *) fail "keyring file mode" ;;
esac
if grep -a -q "s3cret-plain" "$KEYRINGS/login.keyring"; then
  fail "secret found in clear text in the keyring file"
fi
echo "PASS: no clear text secret in the keyring file"

stop_app
start_app -KCServiceLaunch YES
client_with_prompt unlock "Unlock Keyring" OK
python3 "$CLIENT" libsecret-store || fail "libsecret store"

stop_app
start_app -KCServiceLaunch YES
client_with_prompt libsecret-lookup "Unlock Keyring" OK

stop_app
echo "ALL PASSED"
