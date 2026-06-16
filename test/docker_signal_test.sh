#!/bin/sh
# Host-side test: the real `docker stop` scenario.
#
# `docker stop` sends SIGTERM to the container's PID 1 (zini), waits, then
# SIGKILLs if the container hasn't exited. zini is the ENTRYPOINT, so it is
# PID 1; it must forward SIGTERM to the child so the container stops promptly
# and with the child's exit code. The in-container suite cannot test this
# (it would have to kill its own PID 1), so we drive it from the host here.
set -u

IMAGE="${IMAGE:-zini-test}"
fails=0
ok()   { printf '  ok   - %s\n' "$1"; }
fail() { printf '  FAIL - %s\n' "$1"; fails=$((fails + 1)); }

echo "zini docker-stop (PID 1 signal forwarding) test"

# --- positive: child traps SIGTERM and exits 0 -------------------------------
# If zini forwards SIGTERM, the trap fires, the child exits 0, and the container
# exits 0 almost instantly. If it did NOT forward, docker would wait the full
# timeout and SIGKILL -> exit 137, slowly.
cid=$(docker run -d "$IMAGE" /scripts/child-clean.sh)
sleep 0.7
start=$(date +%s)
docker stop -t 10 "$cid" >/dev/null
end=$(date +%s)
elapsed=$((end - start))
rc=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
docker rm "$cid" >/dev/null

if [ "$rc" = "0" ]; then
    ok "docker stop -> container exited 0 (zini forwarded SIGTERM to child)"
else
    fail "container exit code was $rc, expected 0"
fi
if [ "$elapsed" -lt 5 ]; then
    ok "stopped promptly (${elapsed}s, no SIGKILL fallback)"
else
    fail "stop took ${elapsed}s -> SIGTERM was not forwarded (docker fell back to SIGKILL)"
fi

# --- negative control: child ignores SIGTERM ---------------------------------
# Confirms the assertions above actually discriminate: a child that ignores
# SIGTERM forces docker's SIGKILL fallback -> exit 137 (128 + 9).
cid2=$(docker run -d "$IMAGE" /scripts/child-stubborn.sh)
sleep 0.7
docker stop -t 2 "$cid2" >/dev/null
rc2=$(docker inspect -f '{{.State.ExitCode}}' "$cid2")
docker rm "$cid2" >/dev/null
if [ "$rc2" = "137" ]; then
    ok "control: TERM-ignoring child is SIGKILLed by docker (137)"
else
    fail "control expected 137, got $rc2"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "docker-stop test passed."
    exit 0
else
    echo "$fails docker-stop test(s) failed."
    exit 1
fi
