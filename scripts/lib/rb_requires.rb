#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: ruby --disable-gems rb_requires.rb <root> <NUL-separated file names | --builtin. Prints one line a require,
# require<TAB>file<TAB>kind<TAB>path<TAB>scope, or error<TAB>file<TAB>message for a file it cannot parse

require "prism"

# Classes whose rescue clause catches a failed require: LoadError descends from ScriptError
LOAD_ERRORS = %w[LoadError ScriptError Exception].freeze
CALLS = { require: "require", require_relative: "relative", load: "load" }.freeze
# The values of Ruby on Arch that tests of the engine and the platform compare
CONSTANTS = { "RUBY_ENGINE" => "ruby", "RUBY_PLATFORM" => "x86_64-linux" }.freeze

# Decides the tests of RUBY_ENGINE, RUBY_PLATFORM and Gem.win_platform? as Ruby on Arch does: true,
# false, or nil for a test it does not know
module Tests
  module_function

  def evaluate(node)
    case node
    when Prism::ParenthesesNode
      body = node.body
      body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? evaluate(body.body.first) : nil
    when Prism::AndNode then join(evaluate(node.left), evaluate(node.right), false)
    when Prism::OrNode then join(evaluate(node.left), evaluate(node.right), true)
    when Prism::CallNode then call(node)
    end
  end

  # The value that decides a join of two tests alone, false for and and true for or
  def join(left, right, decides)
    return decides if left == decides || right == decides
    return nil if left.nil? || right.nil?

    !decides
  end

  def call(node)
    args = node.arguments&.arguments || []
    if node.name == :! && args.empty?
      value = evaluate(node.receiver)
      return value.nil? ? nil : !value
    end
    return false if node.name == :win_platform? && args.empty? && constant(node.receiver) == "Gem"
    return nil unless args.size == 1

    text = CONSTANTS[constant(node.receiver)]
    other = args.first
    # A regex or a string can stand left of the constant, as in /darwin/ =~ RUBY_PLATFORM
    text, other = CONSTANTS[constant(other)], node.receiver if text.nil? && %i[== != =~ !~].include?(node.name)
    text.nil? ? nil : compare(node.name, text, other)
  end

  def compare(name, text, other)
    case name
    when :==, :!= then other.is_a?(Prism::StringNode) ? (text == other.unescaped) == (name == :==) : nil
    when :include?, :start_with?, :end_with? then other.is_a?(Prism::StringNode) ? text.public_send(name, other.unescaped) : nil
    when :=~, :match?, :match then match(text, other)
    when :!~ then (matched = match(text, other)).nil? ? nil : !matched
    end
  end

  def match(text, node)
    return nil unless node.is_a?(Prism::RegularExpressionNode)

    options = (node.ignore_case? ? Regexp::IGNORECASE : 0) | (node.extended? ? Regexp::EXTENDED : 0) |
              (node.multi_line? ? Regexp::MULTILINE : 0)
    Regexp.new(node.unescaped, options, timeout: 1).match?(text)
  rescue RegexpError
    nil
  end

  def constant(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode then node.parent.nil? ? node.name.to_s : nil
    end
  end
end

# Collects the requires of one file with the scope each runs in
class Requires < Prism::Visitor
  attr_reader :lines

  def initialize(root, file)
    super()
    @root = root
    @file = file
    @scopes = []
    @lines = []
  end

  def visit_def_node(node)
    within(:method) { super }
  end

  def visit_call_node(node)
    if node.receiver.nil? && node.name == :define_method && node.block
      visit(node.arguments) if node.arguments
      within(:method) { visit(node.block) }
      return
    end
    record(node) if CALLS.key?(node.name) && (node.receiver.nil? || constant_name(node.receiver) == "Kernel")
    super
  end

  def visit_if_node(node)
    branches(node.predicate, Tests.evaluate(node.predicate), node.statements, node.subsequent)
  end

  def visit_unless_node(node)
    value = Tests.evaluate(node.predicate)
    branches(node.predicate, value.nil? ? nil : !value, node.statements, node.else_clause)
  end

  def visit_begin_node(node)
    return super unless catches_load_errors?(node.rescue_clause)

    within(:optional) do
      visit(node.statements) if node.statements
      visit(node.rescue_clause)
    end
    visit(node.else_clause) if node.else_clause
    visit(node.ensure_clause) if node.ensure_clause
  end

  private

  # Visits the test, and the branches that the value of the test can take
  def branches(test, value, body, other)
    visit(test)
    visit(body) if body && value != false
    visit(other) if other && value != true
  end

  def within(scope)
    @scopes.push(scope)
    yield
  ensure
    @scopes.pop
  end

  def scope
    return "method" if @scopes.include?(:method)
    return "optional" if @scopes.include?(:optional)

    "module"
  end

  def constant_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode then node.name.to_s
    end
  end

  def catches_load_errors?(clause)
    while clause
      return true if clause.exceptions.any? { |exception| LOAD_ERRORS.include?(constant_name(exception)) }

      clause = clause.subsequent
    end
    false
  end

  def record(node)
    argument = node.arguments&.arguments&.first
    return unless argument.is_a?(Prism::StringNode)

    path = argument.unescaped
    kind = CALLS[node.name]
    if kind == "relative"
      path = "#{path}.rb" unless path.end_with?(".rb")
      # absolute_path expands no ~, which require_relative reads as a directory name
      full = File.absolute_path(path, File.dirname(File.join(@root, @file)))
      path = full.delete_prefix("#{File.absolute_path(@root)}/")
    end
    return if path.match?(/[\t\n\r]/)

    @lines << "require\t#{@file}\t#{kind}\t#{path}\t#{scope}"
  end
end

def main(argv)
  if argv == ["--builtin"]
    $LOADED_FEATURES.reject { |feature| feature.include?("/") }.each { |feature| puts feature.sub(/\.(rb|so)\z/, "") }
    return 0
  end
  if argv.length != 1 || !File.directory?(argv[0])
    warn "Usage: ruby --disable-gems rb_requires.rb <root> <NUL-separated file names | --builtin"
    return 2
  end
  root = argv[0]
  # The names come on stdin, since Linux limits the length of the arguments
  $stdin.binmode.read.split("\0").each do |file|
    next if file.empty?

    file.force_encoding(Encoding.default_external)
    result = Prism.parse_file(File.join(root, file))
    if result.failure?
      puts "error\t#{file}\t#{result.errors.first.message.gsub(/\s+/, ' ')}"
      next
    end
    visitor = Requires.new(root, file)
    result.value.accept(visitor)
    visitor.lines.each { |line| puts line }
  # SystemStackError is no StandardError, and one deep file would end the helper
  rescue SystemCallError, IOError, ArgumentError, EncodingError, SystemStackError => e
    puts "error\t#{file}\t#{e.message.gsub(/\s+/, ' ')}"
  end
  0
end

exit main(ARGV)
