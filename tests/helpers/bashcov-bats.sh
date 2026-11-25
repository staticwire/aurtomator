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

# bashcov resolves the path of a traced script only when it reads the line, so the tests keep
# their directories in this TMPDIR until bashcov, the parent of this script, exits
TMPDIR=$(mktemp -d)
export TMPDIR AURTOMATOR_KEEP_TEST_DIRS=1
(tail --pid="$PPID" -f /dev/null && rm -rf "$TMPDIR") </dev/null >/dev/null 2>&1 {trace_fd}>&- &

# coverage.py measures scripts/lib/py_imports.py through the python3 of cov-shims; -I keeps the
# coverage/ directory of the reports from standing in for the coverage module
helpers=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset COVERAGE_FILE
if python3 -I -m coverage --version >/dev/null 2>&1; then
  mkdir -p coverage
  rm -f coverage/.coverage coverage/.coverage.* coverage/python.xml
  export COVERAGE_FILE="$PWD/coverage/.coverage"
  export PATH="$helpers/cov-shims:$PATH"
fi
# SimpleCov measures scripts/lib/rb_requires.rb through the ruby of cov-shims, in a directory of its
# own, since it merges the results of the last 600 seconds alone by default
unset SIMPLECOV_HELPER_DIR
if ruby -e 'require "simplecov"; require "simplecov-cobertura"' >/dev/null 2>&1; then
  mkdir -p coverage
  rm -rf coverage/ruby coverage/ruby.xml
  export SIMPLECOV_HELPER_DIR="$PWD/coverage/ruby"
  [[ ":$PATH:" == *":$helpers/cov-shims:"* ]] || export PATH="$helpers/cov-shims:$PATH"
fi

# Every writer of a blocking pipe waits for bashcov, so only the records of .sh files reach it.
# Records start with one or more + and BASHCOV> and the delimiter; the second field is BASH_SOURCE.
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
if [[ -n "${COVERAGE_FILE:-}" ]] && compgen -G "$COVERAGE_FILE.*" >/dev/null; then
  # The data names scripts/lib/py_imports.py relative to the root of aurtomator
  (cd "$helpers/../.." && python3 -I -m coverage combine --rcfile=.coveragerc &&
    python3 -I -m coverage xml --rcfile=.coveragerc -o "${COVERAGE_FILE%/*}/python.xml") >&2 || status=1
fi
if [[ -n "${SIMPLECOV_HELPER_DIR:-}" && -f "$SIMPLECOV_HELPER_DIR/.resultset.json" ]]; then
  # shellcheck disable=SC2016 # the code is Ruby
  ruby -e 'require "simplecov"; require "simplecov-cobertura"
    SimpleCov.collate([File.join(ARGV[1], ".resultset.json")]) do
      root ARGV[0]
      coverage_dir ARGV[1]
      formatter SimpleCov::Formatter::CoberturaFormatter
    end' "$helpers/../.." "$SIMPLECOV_HELPER_DIR" >&2 &&
    mv "$SIMPLECOV_HELPER_DIR/coverage.xml" "${SIMPLECOV_HELPER_DIR%/*}/ruby.xml" || status=1
fi
exit "$status"
