#!/bin/sh
# Test helper: spawn a grandchild that exits shortly and orphans it (this script
# returns immediately), so PID 1 (zini) must reap it.
( sleep 0.3; exit 0 ) &
