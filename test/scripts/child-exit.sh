#!/bin/sh
# Test child: exits immediately with the given code (default 0). Used to check
# that a child exiting on its own propagates (zini exits with the same code).
exit "${1:-0}"
