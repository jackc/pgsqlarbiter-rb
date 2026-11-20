# frozen_string_literal: true

# Mutation tests for the name-resolution rules: checks that each rule is
# actually tested, by breaking it and seeing which checks notice.
#
#   rake test:mutation                     (connection from PG* variables)
#   ruby test/mutation.rb [NAME...]
#
# Each mutation below weakens one rule in lib/pgsqlarbiter/analyzer.rb so that
# a query could be judged allowed when it is not. For each one, the repository
# is copied to a temporary directory, the mutation applied there, and the unit
# tests, the corpus oracle and the name fuzzer run against the copy. A mutation
# that none of them catches is a rule without a test. The run fails if any
# mutation survives, or if a mutation's text no longer matches the source
# (update it to match the rule as it is now written).
#
# A mutation marked equivalent cannot change any verdict on SQL PostgreSQL
# accepts, for the reason given. It is still run: should it ever be caught,
# the reason no longer holds and the mark should go.
#
# The live checks need a PostgreSQL server, as for rake test:postgres.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
ANALYZER = "lib/pgsqlarbiter/analyzer.rb"
FUZZ_SEEDS = [1, 2, 3].freeze

Mutation = Struct.new(:name, :rule, :from, :to, :equivalent)

# OLD, NEW and EXCLUDED belong to an INSERT, UPDATE, DELETE or MERGE, which
# PostgreSQL allows only at the top level, so there is no outer level for the
# walk to go on to. They are added for RETURNING and ON CONFLICT, after every
# FROM item, so they are never among a join's members either.
TOP_LEVEL_ONLY = "pseudo entries exist only at the top level, outside any join"

MUTATIONS = [
  # 0.3.1: a reused alias resolves to the nearest query level.
  Mutation.new("schema-qualified-stops-at-nearest",
    "A schema-qualified qualifier never stops at the nearest FROM item of its name.",
    "nearest = names.length == (star ? 1 : 2)", "nearest = true"),
  Mutation.new("stop-at-hidden-entry",
    "An entry hidden by a join alias does not stop the walk outward.",
    "stop = entries.any? { |entry| !entry.hidden && !entry.pseudo }", "stop = entries.any? { |entry| !entry.pseudo }"),
  Mutation.new("stop-at-pseudo-entry",
    "OLD, NEW and EXCLUDED do not stop the walk outward.",
    "stop = entries.any? { |entry| !entry.hidden && !entry.pseudo }", "stop = entries.any? { |entry| !entry.hidden }",
    TOP_LEVEL_ONLY),
  Mutation.new("cte-sees-statement-from",
    "A CTE body cannot see the FROM items of the statement the WITH is attached to.",
    "@stack << -> { @level = level }\n", "\n"),
  # 0.3.2: ON-clause visibility.
  Mutation.new("from-clause-sees-everything",
    "Inside a FROM clause, outside an ON condition, no item of the level is certainly visible.",
    "level.on_clause || NOTHING_VISIBLE", "level.on_clause"),
  Mutation.new("on-clause-sees-earlier-items",
    "An ON condition sees only the members of its own join.",
    "level.on_clause = (start...level.entries.length)", "level.on_clause = (0...level.entries.length)"),
  Mutation.new("visible-through-join-alias",
    "A member hidden by a join alias inside the join is not visible in its ON condition.",
    "scope.cover?(entry.position) && !(hidden && hidden < scope.end) && !entry.pseudo",
    "scope.cover?(entry.position) && !entry.pseudo"),
  Mutation.new("pseudo-visible-in-on-clause",
    "OLD, NEW and EXCLUDED are not visible in an ON condition.",
    "scope.cover?(entry.position) && !(hidden && hidden < scope.end) && !entry.pseudo",
    "scope.cover?(entry.position) && !(hidden && hidden < scope.end)",
    TOP_LEVEL_ONLY),
  Mutation.new("outer-alias-rehides-members",
    "A member's hiding alias is the innermost join alias around it.",
    "members.each { |member| member.hidden ||= level.entries.length }",
    "members.each { |member| member.hidden = level.entries.length }"),
  Mutation.new("scope-leaks-to-parent",
    "Moving out a level, the parent's own scope at that point applies.",
    "scope = level.parent_scope\n", "\n"),
  Mutation.new("stop-on-unseen-entry",
    "Inside FROM, only an entry the reference certainly sees stops the walk.",
    "stop = !seen.empty?", "stop = !entries.empty?")
].freeze

# Outside Bundler, whose load path would put the unmutated lib first.
def run(dir, *command)
  capture = -> { Open3.capture2e(*command, chdir: dir) }
  out, status = defined?(Bundler) ? Bundler.with_unbundled_env(&capture) : capture.call
  [status.success?, out]
end

CHECKS = {
  "unit" => ["ruby", "-Ilib", "-Itest", "-e", 'Dir["test/pgsqlarbiter/test_*.rb"].sort.each { |f| require "./#{f}" }'],
  "corpus" => ["ruby", "test/postgres/oracle.rb"],
  **FUZZ_SEEDS.to_h { |seed| ["fuzz_names:#{seed}", ["ruby", "test/postgres/fuzz_names.rb", "5000", seed.to_s]] }
}.freeze

selected = ARGV.empty? ? MUTATIONS : MUTATIONS.select { |m| ARGV.include?(m.name) }
abort "no such mutation: #{ARGV.join(", ")}" if selected.empty?
source = File.read(File.join(ROOT, ANALYZER))

stale = selected.reject { |m| source.scan(m.from).length == 1 }
abort "mutation text not found exactly once in #{ANALYZER}: #{stale.map(&:name).join(", ")}" unless stale.empty?

def failing_checks(analyzer)
  Dir.mktmpdir("pgsqlarbiter-mutation") do |dir|
    %w[lib test grammar].each { |d| FileUtils.cp_r(File.join(ROOT, d), dir) }
    File.write(File.join(dir, ANALYZER), analyzer)
    CHECKS.select { |_, command| !run(dir, *command)[0] }.keys
  end
end

# A check that fails on the unmutated copy would catch every mutation.
failing = failing_checks(source)
abort "these checks fail without any mutation: #{failing.join(", ")}" unless failing.empty?

survivors = []
selected.each do |mutation|
  caught = failing_checks(source.sub(mutation.from, mutation.to))
  result =
    if !caught.empty?
      "caught by #{caught.join(", ")}#{" (marked equivalent: check the mark)" if mutation.equivalent}"
    elsif mutation.equivalent
      "survived, equivalent: #{mutation.equivalent}"
    else
      survivors << mutation
      "SURVIVED: #{mutation.rule}"
    end
  puts format("%-36s %s", mutation.name, result)
end

abort "#{survivors.length} mutation(s) survived" unless survivors.empty?
