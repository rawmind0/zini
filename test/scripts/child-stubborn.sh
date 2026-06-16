#!/bin/sh
# Test child: ignores SIGTERM, forcing the restart-grace -> SIGKILL path.
echo START
trap '' TERM
while true; do sleep 0.2; done
