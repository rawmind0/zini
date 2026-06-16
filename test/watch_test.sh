#!/bin/sh
# Host-side file-watch e2e tests. Each case runs the test image (zini is PID 1
# via the image entrypoint), configures watching with ZINI_* env vars, runs a
# baked child script, mutates a baked /fix/* fixture, and checks the restart
# count (the child prints START once per spawn).
#
# All fixtures and child scripts live in the image (see Dockerfile.tests), so
# this only drives scenarios. Usage: IMAGE=zini-test sh test/watch_test.sh
set -u

IMAGE="${IMAGE:-zini-test}"
CLEAN=/scripts/child-clean.sh
STUBBORN=/scripts/child-stubborn.sh
fails=0
ok()   { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# run <name> <docker-run args...>   (detached; image + command are part of args)
run()    { docker rm -f "$1" >/dev/null 2>&1 || true; name=$1; shift; docker run -d --name "$name" "$@" >/dev/null; }
ex()     { docker exec "$1" sh -c "$2"; }
starts() { docker logs "$1" 2>&1 | grep -c '^START'; }
hups()   { docker logs "$1" 2>&1 | grep -c '^GOTHUP'; }
clean()  { docker rm -f "$1" >/dev/null 2>&1 || true; }

echo "zini file-watch tests"

run w1 -e ZINI_WATCH=/fix/file "$IMAGE" "$CLEAN"
sleep 1; ex w1 'echo a > /fix/file'; sleep 1
n=$(starts w1); [ "$n" -ge 2 ] && ok "in-place write restarts (starts=$n)" || fail "in-place write (starts=$n)"; clean w1

run w2 -e ZINI_WATCH=/fix/file "$IMAGE" "$CLEAN"
sleep 1; ex w2 'echo a > /fix/.t && mv /fix/.t /fix/file'; sleep 1
n=$(starts w2); [ "$n" -ge 2 ] && ok "temp+rename restarts (starts=$n)" || fail "temp+rename (starts=$n)"; clean w2

# kubernetes-style rotation: swap ..data, delete the old timestamped dir
run w3 -e ZINI_WATCH=/fix/k8s/cfg "$IMAGE" "$CLEAN"
sleep 1
ex w3 'mkdir -p /fix/k8s/..2024b && echo v2 > /fix/k8s/..2024b/cfg && ln -sfn ..2024b /fix/k8s/..data && rm -rf /fix/k8s/..2024a'
sleep 1
n=$(starts w3); [ "$n" -ge 2 ] && ok "k8s rotation restarts (starts=$n)" || fail "k8s rotation (starts=$n)"; clean w3

run w4 -e ZINI_WATCH=/fix/file -e ZINI_DEBOUNCE=500 "$IMAGE" "$CLEAN"
sleep 1; ex w4 'for i in 1 2 3 4 5; do echo $i > /fix/file; done'; sleep 2
n=$(starts w4); [ "$n" -eq 2 ] && ok "debounce coalesces burst (starts=$n)" || fail "debounce (starts=$n)"; clean w4

run w5 -e ZINI_WATCH=/fix/file -e ZINI_ON_CHANGE=signal -e ZINI_RELOAD_SIGNAL=SIGHUP "$IMAGE" "$CLEAN"
sleep 1; ex w5 'echo a > /fix/file'; sleep 1
s=$(starts w5); h=$(hups w5)
{ [ "$s" -eq 1 ] && [ "$h" -ge 1 ]; } && ok "signal mode sends SIGHUP, no respawn (starts=$s hups=$h)" || fail "signal mode (starts=$s hups=$h)"; clean w5

# tini exit model: a child exiting on its own propagates even with watching on
run w6 -e ZINI_WATCH=/fix/file "$IMAGE" /scripts/child-exit.sh 7
rc=$(docker wait w6); [ "$rc" = "7" ] && ok "self-exit propagates, no respawn (exit $rc)" || fail "self-exit (exit $rc)"; clean w6

run w8 -e ZINI_WATCH=/fix/dir "$IMAGE" "$CLEAN"
sleep 1; ex w8 'echo a > /fix/dir/file'; sleep 1
n=$(starts w8); [ "$n" -ge 2 ] && ok "directory target restarts (starts=$n)" || fail "directory target (starts=$n)"; clean w8

run w9 -e ZINI_WATCH=/fix/linkdir "$IMAGE" "$CLEAN"
sleep 1; ex w9 'echo a > /fix/dir/f'; sleep 1
n=$(starts w9); [ "$n" -ge 2 ] && ok "symlinked dir restarts (starts=$n)" || fail "symlinked dir (starts=$n)"; clean w9

# symlinked file: in-place write through the link
run w10 -e ZINI_WATCH=/fix/link "$IMAGE" "$CLEAN"
sleep 1; ex w10 'echo v2 > /fix/link'; sleep 1
n=$(starts w10); [ "$n" -ge 2 ] && ok "symlinked file in-place restarts (starts=$n)" || fail "symlinked file (starts=$n)"; clean w10

# recovery: non-atomic remove+recreate must not permanently lose the watch
run w11 -e ZINI_WATCH=/fix/link -e ZINI_DEBOUNCE=1500 "$IMAGE" "$CLEAN"
sleep 1; ex w11 'rm /fix/file'; sleep 0.5; ex w11 'echo v2 > /fix/file'; sleep 2
ex w11 'echo v3 > /fix/file'; sleep 2
n=$(starts w11); [ "$n" -ge 3 ] && ok "watch recovers after remove+recreate (starts=$n)" || fail "watch recovery (starts=$n)"; clean w11

# restart grace: TERM-ignoring child is SIGKILLed, then respawned
run w7 -e ZINI_WATCH=/fix/file -e ZINI_RESTART_GRACE=1 "$IMAGE" "$STUBBORN"
sleep 1; ex w7 'echo a > /fix/file'; sleep 3
n=$(starts w7); [ "$n" -ge 2 ] && ok "grace SIGKILL restarts (starts=$n)" || fail "grace SIGKILL (starts=$n)"; clean w7

# the -W flag path (entrypoint override) works end-to-end too
run wf --entrypoint /usr/local/bin/zini "$IMAGE" -W /fix/file -- "$CLEAN"
sleep 1; ex wf 'echo a > /fix/file'; sleep 1
n=$(starts wf); [ "$n" -ge 2 ] && ok "-W flag restarts (starts=$n)" || fail "-W flag (starts=$n)"; clean wf

echo
if [ "$fails" -eq 0 ]; then
    echo "All file-watch tests passed."
    exit 0
else
    echo "$fails file-watch test(s) failed."
    exit 1
fi
