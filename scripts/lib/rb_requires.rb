#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: ruby --disable-gems rb_requires.rb <root> <NUL-separated file names | --builtin. Prints one line a require,
# require<TAB>file<TAB>kind<TAB>path<TAB>scope, or error<TAB>file<TAB>message for a file it cannot parse

require "prism"

# Classes whose rescue clause catches a failed require: LoadError descends from ScriptError
LOAD_ERRORS = %w[LoadError ScriptError Exception].freeze
CALLS = { require: "require", require_relative: "relative", load: "load" }.freeze

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
      full = File.expand_path(path, File.dirname(File.join(@root, @file)))
      path = full.delete_prefix("#{File.expand_path(@root)}/")
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
  rescue SystemCallError, IOError, ArgumentError, EncodingError => e
    puts "error\t#{file}\t#{e.message.gsub(/\s+/, ' ')}"
  end
  0
end

exit main(ARGV)
