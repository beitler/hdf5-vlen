#!/usr/bin/env bash
# Run the minimal reproducer against everything `make` built, and CHECK the
# outcome:
#
#   *-patched  must be clean         -- the fix removes the bug
#   everything else must crash       -- SIGSEGV, or use-after-free under ASan
#
# Exits non-zero if any run disagree.

set -uo pipefail
TOP="$(cd "$(dirname "$0")" && pwd)"
ulimit -c 0

LOGDIR="${RUN_ALL_LOGDIR:-$TOP/logs/run}"
REPORTS_MARKER="=== sanitizer reports and failure details ==="
PRINT_REPORTS=1
[ "${1:-}" = "--no-reports" ] && PRINT_REPORTS=0

FAILURES=0
VERDICT=""
UNEXPECTED=()          # labels whose outcome disagreed with expectations
REPORTED=()            # labels already shown in the reports section

mkdir -p "$LOGDIR"
rm -f "$LOGDIR"/*.log

# $1 = log file for this run, $2... = command
run() { local log="$1"; shift; timeout 180 bash -c 'exec "$0" "$@"' "$@" >"$log" 2>&1; }

# $1 = exit status, $2 = log file. The sanitizer names the bug it found, so
# prefer that over guessing from the exit status.
verdict() {
    local kind
    kind="$(sed -n 's/.*ERROR: \(Address\|Leak\)Sanitizer: \([A-Za-z-]*\).*/\2/p' "$2" | head -1)"
    case "$1" in
        0)   echo "clean" ;;
        139) echo "SIGSEGV" ;;
        124) echo "TIMEOUT" ;;
        *)   [ -n "$kind" ] && echo "ASan: $kind" || echo "exit $1" ;;
    esac
}

# $1 = label, $2 = exit status. Patched builds must be clean; the rest must not.
# The answer comes back in $VERDICT rather than on stdout: this has to run in
# the current shell, because a $(check ...) inside the printf would bump
# FAILURES in a subshell and the script would always exit 0.
check() {
    local label="$1" rc="$2"
    case "$label" in
        *patched*) if [ "$rc" -eq 0 ]; then VERDICT="ok"
                   else VERDICT="UNEXPECTED"; FAILURES=$((FAILURES+1)); UNEXPECTED+=("$label"); fi ;;
        *)         if [ "$rc" -ne 0 ]; then VERDICT="ok (bug present)"
                   else VERDICT="UNEXPECTED (fixed?)"; FAILURES=$((FAILURES+1)); UNEXPECTED+=("$label"); fi ;;
    esac
}

asan_report() {
    awk 'n >= 200 { print "  [...] truncated -- see the full log"; exit }
         /(ERROR|WARNING): (Address|Leak)Sanitizer/ { in_report = 1 }
         in_report { print; n++ }
         in_report && /^SUMMARY: / { exit }' "$1"
}

# Results go to stdout, and a crash is the expected outcome for half of these;
# only this shell can suppress its own job-control notices about them.
exec 2>/dev/null

hr() { printf '%s\n' "-------------------------------  -------------------------  ---------"; }
row() { printf "%-31s  %-25s  %s\n" "$1" "$2" "$3"; }

row "C binary (libhdf5 build)" "result" "expected?"
hr
for bin in "$TOP"/bin/vlen_minimal-*; do
    [ -x "$bin" ] || continue
    label="$(basename "$bin")"; label="${label#vlen_minimal-}"
    log="$LOGDIR/c-$label.log"
    run "$log" "$bin"; rc=$?              # capture before any $(...) resets $?
    check "$label" $rc
    row "$label" "$(verdict $rc "$log")" "$VERDICT"
done

echo
row "venv (h5py on that libhdf5)" "result" "expected?"
hr
for venv in "$TOP"/.venv-*; do
    py="$venv/bin/python"
    [ -x "$py" ] || continue
    label="$(basename "$venv")"; label="${label#.venv-}"
    log="$LOGDIR/py-$label.log"
    run "$log" "$py" "$TOP/vlen_minimal.py"; rc=$?
    check "$label" $rc
    row "$label" "$(verdict $rc "$log")" "$VERDICT"
done

echo
echo "per-run output captured in ${LOGDIR#$TOP/}/"
if [ "$FAILURES" -eq 0 ]; then
    echo "all runs matched expectations"
else
    echo "$FAILURES run(s) did NOT match expectations"
fi

# --- the reports section, split off by the CI job on $REPORTS_MARKER --------
if [ "$PRINT_REPORTS" -eq 1 ]; then
    reports="$(
        for log in "$LOGDIR"/*.log; do
            [ -s "$log" ] || continue
            grep -q "Sanitizer" "$log" || continue
            name="$(basename "$log" .log)"
            REPORTED+=("$name")
            echo "---- $name ----"
            asan_report "$log"
            echo
        done
        # Anything that disagreed with expectations and has no sanitizer report
        # of its own -- show the tail of its output, that is all there is.
        for label in ${UNEXPECTED[@]+"${UNEXPECTED[@]}"}; do
            for log in "$LOGDIR"/*-"$label".log; do
                [ -f "$log" ] || continue
                name="$(basename "$log" .log)"
                case " ${REPORTED[*]-} " in *" $name "*) continue ;; esac
                echo "---- $name (unexpected outcome, last 40 lines) ----"
                if [ -s "$log" ]; then tail -40 "$log"; else echo "  (the run produced no output)"; fi
                echo
            done
        done
    )"
    if [ -n "$reports" ]; then
        echo
        echo "$REPORTS_MARKER"
        echo
        printf '%s\n' "$reports"
    fi
fi

exit $((FAILURES > 0))
