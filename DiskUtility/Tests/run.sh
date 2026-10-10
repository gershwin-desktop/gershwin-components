#!/bin/sh
# Builds and runs the DiskUtility Wave-1 unit test suite, prints per-tool
# PASS counts and exits nonzero when any assertion fails or a tool crashes.

# No set -u: GNUstep.sh probes ZSH_VERSION and friends unguarded.

cd "$(dirname "$0")" || exit 2

if [ -f /System/Library/Makefiles/GNUstep.sh ]; then
    # shellcheck disable=SC1091
    . /System/Library/Makefiles/GNUstep.sh
fi

TOOLS="t_Parsing t_PartitionLayout t_Models t_MockBackend t_SHA256 t_Libraries"

gmake || exit 2

status=0
for tool in $TOOLS; do
    binary="./obj/$tool"
    if [ ! -x "$binary" ]; then
        echo "$tool: MISSING BINARY"
        status=1
        continue
    fi
    output=$("$binary" 2>&1)
    code=$?
    passed=$(printf '%s\n' "$output" | grep -c '^Passed test:')
    failed=$(printf '%s\n' "$output" | grep -c '^Failed test:')
    crashed=$(printf '%s\n' "$output" | grep -c 'Uncaught exception')
    echo "$tool: $passed passed, $failed failed, $crashed uncaught"
    if [ "$failed" -ne 0 ] || [ "$crashed" -ne 0 ] || [ "$code" -ne 0 ]; then
        printf '%s\n' "$output" | grep -E '^Failed test:|Uncaught exception'
        status=1
    fi
done

# Tests/Manager has its own makefile: DUStorageManager pulls in the whole
# operation and notification graph, which does not belong in the ARC support
# library the tools above share. It is hermetic like them, so it is part of
# this suite rather than an on-demand extra.
if [ -d Manager ]; then
    (cd Manager && gmake) || status=1
    binary="./Manager/obj/t_StorageManager"
    if [ ! -x "$binary" ]; then
        echo "t_StorageManager: MISSING BINARY"
        status=1
    else
        output=$("$binary" 2>&1)
        code=$?
        summary=$(printf '%s\n' "$output" | grep '^== summary ==')
        passed=$(printf '%s\n' "$output" | grep -c '^  ok  ')
        failed=$(printf '%s\n' "$output" | grep -c '^  FAIL')
        echo "t_StorageManager: $passed passed, $failed failed"
        if [ "$failed" -ne 0 ] || [ "$code" -ne 0 ]; then
            printf '%s\n' "$output" | grep '^  FAIL'
            status=1
        fi
    fi
fi

exit $status
