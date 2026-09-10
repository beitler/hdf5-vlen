#!/usr/bin/env bash
# Run the minimal reproducer against everything `make` built, and CHECK the
# outcome rather than just printing it:
#
#   *-patched  must be clean         -- the fix removes the bug
#   everything else must crash       -- SIGSEGV, or use-after-free under ASan
#
# Exits non-zero if any run disagrees, so this works as a test.
# One process, one read, no threads -- see vlen_minimal.c.
set -uo pipefail
TOP="$(cd "$(dirname "$0")" && pwd)"
ulimit -c 0

FAILURES=0

run() { timeout 180 bash -c 'exec "$0" "$@" >/dev/null 2>&1' "$@"; }

verdict() { case "$1" in
    0)   echo "clean" ;;
    139) echo "SIGSEGV" ;;
    1)   echo "ASan: use-after-free" ;;
    124) echo "TIMEOUT" ;;
    *)   echo "exit $1" ;;
  esac; }

# $1 = label, $2 = exit status. Patched builds must be clean; the rest must not.
check() {
    local label="$1" rc="$2"
    case "$label" in
        *patched*) [ "$rc" -eq 0 ] && echo "ok" || { FAILURES=$((FAILURES+1)); echo "UNEXPECTED"; } ;;
        *)         [ "$rc" -eq 0 ] && { FAILURES=$((FAILURES+1)); echo "UNEXPECTED (fixed?)"; } || echo "ok (bug present)" ;;
    esac
}

# Results go to stdout, and a crash is the expected outcome for half of these;
# only this shell can suppress its own job-control notices about them.
exec 2>/dev/null

hr() { printf '%s\n' "-------------------------------  ---------------------  ---------"; }

printf "%-31s  %-21s  %s\n" "C binary (libhdf5 build)" "result" "expected?"
hr
for bin in "$TOP"/bin/vlen_minimal-*; do
    [ -x "$bin" ] || continue
    label="$(basename "$bin")"; label="${label#vlen_minimal-}"
    run "$bin"; rc=$?                    # capture before any $(...) resets $?
    printf "%-31s  %-21s  %s\n" "$label" "$(verdict $rc)" "$(check "$label" $rc)"
done

echo
printf "%-31s  %-21s  %s\n" "venv (h5py on that libhdf5)" "result" "expected?"
hr
for venv in "$TOP"/.venv-*; do
    py="$venv/bin/python"
    [ -x "$py" ] || continue
    label="$(basename "$venv")"; label="${label#.venv-}"
    run "$py" "$TOP/vlen_minimal.py"; rc=$?
    printf "%-31s  %-21s  %s\n" "$label" "$(verdict $rc)" "$(check "$label" $rc)"
done

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "all runs matched expectations"
else
    echo "$FAILURES run(s) did NOT match expectations"
fi
exit $((FAILURES > 0))
