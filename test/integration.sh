#!/bin/sh
# End-to-end checks for zini. Run inside a Linux container (see Dockerfile).
# The container entrypoint runs this script *under* zini, so the outer zini is
# PID 1; the cases below additionally invoke zini as a normal child process.
set -u

ZINI="${ZINI:-/usr/local/bin/zini}"
fails=0

ok()   { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# check_exit <expected> <description> <command...>
check_exit() {
    expected=$1; desc=$2; shift 2
    "$@" >/dev/null 2>&1
    got=$?
    if [ "$got" -eq "$expected" ]; then ok "$desc (exit $got)"; else fail "$desc (expected $expected, got $got)"; fi
}

echo "zini integration tests (running as PID $$)"

# --- informational flags -----------------------------------------------------
"$ZINI" --version 2>&1 | grep -q "zini version" && ok "--version prints version" || fail "--version output"
check_exit 0 "--version exits 0" "$ZINI" --version
check_exit 0 "-h exits 0"        "$ZINI" -h
"$ZINI" -l 2>&1 | grep -q "MIT License" && ok "-l prints license" || fail "-l output"
check_exit 1 "no program exits 1" "$ZINI"

# --- exit-code handling ------------------------------------------------------
check_exit 0   "passthrough exit 0"   "$ZINI" -- true
check_exit 42  "passthrough exit 42"  "$ZINI" -- sh -c 'exit 42'
check_exit 143 "killed by SIGTERM=143" "$ZINI" -- sh -c 'kill -TERM $$'
check_exit 0   "-e 42 remaps to 0"    "$ZINI" -e 42 -- sh -c 'exit 42'
check_exit 127 "missing command = 127" "$ZINI" -- this-command-does-not-exist
# permission denied = 126
noexec=/tmp/zini_noexec
printf '#!/bin/sh\n' > "$noexec"; chmod 644 "$noexec"
check_exit 126 "non-executable = 126" "$ZINI" -- "$noexec"

# --- reaper warning when not PID 1 -------------------------------------------
"$ZINI" -- true 2>/tmp/zini_warn.txt
if grep -q "not running as PID 1" /tmp/zini_warn.txt; then
    ok "warns when not PID 1 (and not a subreaper)"
else
    fail "expected reaper warning when not PID 1"
fi

# --- signal forwarding -------------------------------------------------------
# Child traps SIGTERM and exits 0. Sending SIGTERM to zini must reach the child.
# stderr is discarded: this inner zini is intentionally not PID 1, so it would
# (correctly) print the "not running as PID 1" reaper warning.
"$ZINI" -- sh -c 'trap "exit 0" TERM; while true; do sleep 0.1; done' 2>/dev/null &
zpid=$!
sleep 0.5
kill -TERM "$zpid"
wait "$zpid"; rc=$?
if [ "$rc" -eq 0 ]; then ok "forwards SIGTERM to child"; else fail "signal forwarding (rc=$rc)"; fi

# --- zombie reaping ----------------------------------------------------------
# Orphan a grandchild: the inner parent exits immediately, leaving (sleep; exit)
# reparented to PID 1 (the outer zini). It must be reaped, leaving no zombie.
sh -c '( sleep 0.3 ; exit 0 ) &'
sleep 1
zombies=0
for s in /proc/[0-9]*/stat; do
    [ -r "$s" ] || continue
    state=$(sed 's/.*) //' "$s" 2>/dev/null | cut -d' ' -f1)
    [ "$state" = "Z" ] && zombies=$((zombies + 1))
done
if [ "$zombies" -eq 0 ]; then ok "no leftover zombies (orphans reaped)"; else fail "$zombies zombie(s) not reaped"; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "All integration tests passed."
    exit 0
else
    echo "$fails integration test(s) failed."
    exit 1
fi
