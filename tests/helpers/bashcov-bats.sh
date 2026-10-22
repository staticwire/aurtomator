#!/usr/bin/env bash
#
# bashcov-bats.sh - Run bats under bashcov without losing trace lines
#
# Usage: bashcov -- tests/helpers/bashcov-bats.sh [bats argument]...
#
# bashcov 4.0.0 loses trace lines in two ways. Ruby opens the pipe that
# bashcov reads in non-blocking mode, so bash drops a line whenever the
# pipe is full. And bashcov resolves the path of a traced script when it
# reads the line, after the test may have removed the link it ran the
# script from. This script makes the pipe blocking and keeps the test
# directories until bashcov exits. A blocking pipe makes every writer wait
# for bashcov, and bats itself writes most of the trace, so bashcov gets
# only the lines of .sh files.

# bashcov stops reading at a traced line that holds the delimiter of its
# PS4, so this script traces only the bats command
set +x
set -euo pipefail

trace_fd=${BASH_XTRACEFD:?run this script under bashcov}
delimiter=${PS4#*BASHCOV>}
# shellcheck disable=SC2016
delimiter=${delimiter%%'${LINENO-}'*}

ruby -e 'require "io/nonblock"; IO.for_fd(Integer(ARGV[0]), autoclose: false).nonblock = false' "$trace_fd"

# teardown_test_env keeps a test directory while AURTOMATOR_KEEP_TEST_DIRS
# is set. mktemp creates them all in TMPDIR, which a process removes once
# bashcov, the parent of this script, has exited.
TMPDIR=$(mktemp -d)
export TMPDIR AURTOMATOR_KEEP_TEST_DIRS=1
(tail --pid="$PPID" -f /dev/null && rm -rf "$TMPDIR") </dev/null >/dev/null 2>&1 {trace_fd}>&- &

# A record starts with one or more + and BASHCOV> and the delimiter, and
# its second field is BASH_SOURCE
exec {filter_fd}> >(LC_ALL=C gawk -v d="$delimiter" '
  BEGIN { RS = "[+]+BASHCOV>" d; ORS = "" }
  NR > 1 && split($0, field, d) > 1 && field[2] ~ /\.sh$/ { print start $0 }
  { start = RT }
' >&"$trace_fd")
filter_pid=$!

# bats runs with the shell options bashcov passed
set +euo pipefail
set -x
BASH_XTRACEFD=$filter_fd bats "$@"
status=$?
set +x
exec {filter_fd}>&-
wait "$filter_pid"
exit "$status"
