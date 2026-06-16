#!/bin/sh
# Test child: kills itself with SIGTERM (zini should report 128 + 15 = 143).
kill -TERM $$
