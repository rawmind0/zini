#!/bin/sh
# Test child: prints START once per (re)spawn, reloads cleanly on SIGTERM
# (exit 0) and logs SIGHUP. Used to count restarts / observe signal handling.
echo START
trap 'echo GOTHUP' HUP
trap 'exit 0' TERM
while true; do sleep 0.2; done
