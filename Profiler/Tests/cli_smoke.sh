#!/bin/sh
# Checks that the command line tool answers, and answers the same as the
# fixtures say. Run it from the Profiler directory after "gmake":
#
#   sh Tests/cli_smoke.sh [path to the profiler tool]
#
# It needs no display, no root and no profiling tools.

set -u
# Everything is found relative to this script, so it runs from anywhere,
# including a CI job that only knows the repository root.
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=${1:-$HERE/../obj/profiler}
FIXTURE=$HERE/Fixtures/example.folded
failed=0

check()
{
    if [ "$2" = "$3" ]; then
        echo "ok      $1"
    else
        echo "FAILED  $1: expected '$3', got '$2'"
        failed=$((failed + 1))
    fi
}

checkContains()
{
    if echo "$2" | grep -q "$3"; then
        echo "ok      $1"
    else
        echo "FAILED  $1: '$3' is not in the output"
        failed=$((failed + 1))
    fi
}

[ -x "$TOOL" ] || { echo "no tool at $TOOL - run gmake first"; exit 1; }

# The recording in the fixture: 1000 samples on 6 call paths, and the solver
# is the most expensive function at 420 of them.
out=$("$TOOL" report "$FIXTURE" --top 3)
checkContains "report names the file" "$out" "example.folded"
checkContains "report counts the call paths" "$out" "6 call paths"
checkContains "report finds the hottest function" "$out" "420 ms.*solveFrom"

out=$("$TOOL" report "$FIXTURE" --top 1 --json)
checkContains "report speaks JSON" "$out" '"functions"'
checkContains "JSON carries the total" "$out" '"total": 1000'

out=$("$TOOL" report "$FIXTURE" --tree --top 3)
checkContains "the tree names the recording at its root" "$out" "example.folded"
checkContains "the tree nests what was called" "$out" "    _start"
checkContains "and keeps nesting deeper" "$out" "      main"

# Our own memory is always readable.
out=$("$TOOL" memory $$)
checkContains "memory says what is in RAM" "$out" "in RAM"
checkContains "memory names the heap" "$out" "Heap"
out=$("$TOOL" memory $$ --by file)
checkContains "memory can add up per file" "$out" "FILE OR MAPPING"
out=$("$TOOL" memory $$ --json)
checkContains "memory speaks JSON" "$out" '"resident"'
out=$("$TOOL" memory --all | head -3)
checkContains "every process can be listed" "$out" "PROGRAM"

# Recording needs a profiling tool and often the rights to use it, so the
# checks here are the ones that hold on any machine: the commands exist,
# they explain themselves, and they refuse clearly when told nothing.
out=$("$TOOL" --help)
checkContains "the help lists record" "$out" "record"
checkContains "the help lists allocations" "$out" "allocations"

"$TOOL" record >/dev/null 2>&1
check "record without a target fails" "$?" "1"
"$TOOL" allocations >/dev/null 2>&1
check "allocations without a process fails" "$?" "1"
out=$("$TOOL" allocations 999999 --for 1 2>&1)
checkContains "allocations says when there is no such process" "$out" "no process"

# What a caller has to be able to rely on.
"$TOOL" report /nonexistent.folded >/dev/null 2>&1
check "a missing recording fails" "$?" "1"
"$TOOL" frobnicate >/dev/null 2>&1
check "an unknown command fails" "$?" "1"
"$TOOL" report "$FIXTURE" >/dev/null 2>&1
check "a good run succeeds" "$?" "0"
"$TOOL" --help >/dev/null 2>&1
check "--help succeeds" "$?" "0"

if [ $failed -eq 0 ]; then
    echo "all checks passed"
    exit 0
fi
echo "$failed check(s) failed"
exit 1
