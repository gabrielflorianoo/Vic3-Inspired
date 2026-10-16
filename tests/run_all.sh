#!/bin/sh
# Runs every headless test script; exit code 0 = all pass. Usage: sh tests/run_all.sh
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in tests/run_tests.gd tests/test_strategy.gd; do
	echo "== $t"
	timeout 600 godot --headless --path . --script "res://$t" || rc=1
done
exit $rc
