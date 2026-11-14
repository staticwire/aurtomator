#!/usr/bin/env bash
#
# bashcov-bats.sh - Run bats under bashcov without losing trace lines
#
# Usage: bashcov -- tests/helpers/bashcov-bats.sh [bats argument]...

# bashcov stops reading at a traced line that holds the delimiter of its
# PS4, so this script traces only the bats command
set +x
set -euo pipefail

trace_fd=${BASH_XTRACEFD:?run this script under bashcov}
delimiter=${PS4#*BASHCOV>}
# shellcheck disable=SC2016
delimiter=${delimiter%%'${LINENO-}'*}

# Ruby opens the trace pipe of bashcov 4.0.0 in non-blocking mode, where bash drops a line
# whenever the pipe is full
ruby -e 'require "io/nonblock"; IO.for_fd(Integer(ARGV[0]), autoclose: false).nonblock = false' "$trace_fd"

# bashcov resolves the path of a traced script only when it reads the line, so the tests keep
# their directories in this TMPDIR until bashcov, the parent of this script, exits
TMPDIR=$(mktemp -d)
export TMPDIR AURTOMATOR_KEEP_TEST_DIRS=1
(tail --pid="$PPID" -f /dev/null && rm -rf "$TMPDIR") </dev/null >/dev/null 2>&1 {trace_fd}>&- &

# Every writer of a blocking pipe waits for bashcov, so only the records of .sh files reach it.
# A record starts with one or more + and BASHCOV> and the delimiter; its second field is BASH_SOURCE.
exec {filter_fd}> >(LC_ALL=C gawk -v d="$delimiter" '
  BEGIN { RS = "[+]+BASHCOV>" d; ORS = "" }
  NR > 1 && split($0, field, d) > 1 && field[2] ~ /\.sh$/ { print start $0 }
  { start = RT }
' >&"$trace_fd")
filter_pid=$!

# bats runs with the shell options bashcov passed. This shell traces nothing more: gawk writes its
# last block only when its input closes, and a line traced here before that can split a record
set +euo pipefail
(
  BASH_XTRACEFD=$filter_fd
  set -x
  exec bats "$@"
)
status=$?
exec {filter_fd}>&-
wait "$filter_pid"
exit "$status"
