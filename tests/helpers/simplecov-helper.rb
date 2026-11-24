# frozen_string_literal: true

# Loaded by tests/helpers/cov-shims/ruby: measures scripts/lib/rb_requires.rb into SIMPLECOV_HELPER_DIR, one
# command name a process and no report, since tests/helpers/bashcov-bats.sh collates the results after bats

require "simplecov"

# Writes no report; the results go to .resultset.json alone
class NoReport
  def format(_result) = nil
end

SimpleCov.root(File.expand_path("../..", __dir__))
SimpleCov.coverage_dir(ENV.fetch("SIMPLECOV_HELPER_DIR"))
SimpleCov.command_name("rb_requires #{Process.pid}")
SimpleCov.merge_timeout(7200)
SimpleCov.print_error_status = false
SimpleCov.formatter(NoReport)
SimpleCov.start do
  add_filter { |source| !source.filename.end_with?("/scripts/lib/rb_requires.rb") }
end
