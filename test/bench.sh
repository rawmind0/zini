#!/bin/sh
# Profile the supervision loop: run the Debug build (zini-debug, baked into the
# test image with the profiler compiled in) as PID 1, idle for a bit, then
# `docker stop` it (SIGTERM) so it forwards the signal, reaps the child, and
# dumps its profile block on exit.
#
# The Debug build's absolute CPU/RSS are not release-representative, but the
# architectural metrics (loop iterations, timeout wakeups, voluntary context
# switches) are. Usage: make bench   (or: IMAGE=zini-test sh test/bench.sh)
set -eu

IMAGE="${IMAGE:-zini-test}"
IDLE="${IDLE:-8}"
NAME=zini-bench

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "running zini-debug (PID 1) supervising 'sleep', idling ${IDLE}s..."
docker run -d --name "$NAME" --entrypoint /usr/local/bin/zini-debug \
    "$IMAGE" -- sleep $((IDLE + 60)) >/dev/null
sleep "$IDLE"
docker stop "$NAME" >/dev/null 2>&1 || true

echo
docker logs "$NAME" 2>&1 | sed -n '/PROF/,$p'
docker rm "$NAME" >/dev/null 2>&1 || true
