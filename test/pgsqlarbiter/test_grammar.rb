# frozen_string_literal: true

require_relative "../test_helper"
require "set"

# Static checks of the analyzer against the grammar it walks.
#
# The analyzer is only fail-closed if every production that carries a table,
# function or type name is covered by a handler. These tests read the extracted
# grammar and prove that coverage, so a PostgreSQL upgrade that adds a new place
# for a name to appear fails here instead of silently going unanalyzed.
class TestGrammar < Minitest::Test
  GRAMMAR = File.expand_path("../../grammar/pg_dml.y", __dir__)
  Analyzer = Pgsqlarbiter::Analyzer

  # Nonterminals that are consumed whole by the handler of the one production
  # that uses them, and are therefore never walked into.
  CONSUMED_BY_PARENT = {
    extended_relation_expr: [:relation_expr],
    OptTempTableName: [:into_clause]
  }.freeze

  def self.productions
    @productions ||= begin
      body = File.read(GRAMMAR)[/^rule\n(.*?)^end$/m, 1]
      rules = Hash.new { |h, k| h[k] = [] }
      body.scan(/^  (\w+): (.*?) ;$/m) do |lhs, alternatives|
        alternatives.split(/\n\s*\|/).each do |alternative|
          symbols = alternative.sub(/\{.*\}/, "").sub(/= \w+\s*\z/, "").split
          rules[lhs.to_sym] << symbols.map { |s| s.start_with?("'") ? s[1..-2] : s.to_sym }
        end
      end
      rules
    end
  end

  def productions
    self.class.productions
  end

  def covered
    Analyzer::HANDLERS.keys.to_set | Analyzer::LABELS | Analyzer::UNSUPPORTED.keys | Analyzer::ROLE_BEARING
  end

  def test_grammar_was_read
    assert_operator productions.size, :>, 250
    assert_includes productions.keys, :PreparableStmt
    assert_equal [[:SelectStmt], [:InsertStmt], [:UpdateStmt], [:DeleteStmt], [:MergeStmt]], productions[:PreparableStmt]
  end

  def test_every_handler_and_label_names_a_real_nonterminal
    (covered | CONSUMED_BY_PARENT.keys).each do |name|
      assert productions.key?(name), "#{name} is not a nonterminal of the grammar"
    end
  end

  def test_every_production_carrying_a_name_is_covered
    productions.each do |lhs, alternatives|
      next unless alternatives.flatten.any? { |symbol| Analyzer::ROLE_BEARING.include?(symbol) }

      assert covered.include?(lhs) || CONSUMED_BY_PARENT.key?(lhs),
        "#{lhs} contains a table, function or type name but the analyzer has no handler for it"
    end
  end

  def test_nonterminals_consumed_by_a_parent_have_no_other_parent
    CONSUMED_BY_PARENT.each do |name, parents|
      users = productions.select { |_, alternatives| alternatives.flatten.include?(name) }.keys
      assert_equal parents.sort, users.sort, "#{name} is used somewhere the analyzer does not expect"
    end
  end

  def test_every_relation_reference_is_handled
    productions.each do |lhs, alternatives|
      next unless alternatives.flatten.any? { |s| [:relation_expr, :relation_expr_opt_alias, :insert_target].include?(s) }

      # These either have a handler or are walked generically into one.
      assert_includes [:table_ref, :simple_select, :relation_expr_opt_alias, :DeleteStmt, :UpdateStmt,
        :MergeStmt, :InsertStmt], lhs
    end
    [:relation_expr, :relation_expr_opt_alias, :insert_target].each do |name|
      assert Analyzer::HANDLERS.key?(name)
    end
  end

  # Every way of writing a type reduces to a nonterminal with a type handler.
  def test_every_type_name_is_handled
    type_handled = lambda do |symbol, seen = Set.new|
      next true if Analyzer::HANDLERS.key?(symbol)
      next false unless productions.key?(symbol) && seen.add?(symbol)

      productions[symbol].all? { |alternative| type_handled.call(alternative.first, seen) }
    end
    [:SimpleTypename, :ConstTypename].each do |name|
      productions[name].each do |alternative|
        assert type_handled.call(alternative.first), "type syntax #{name}: #{alternative.join(" ")} has no handler"
      end
    end
    assert_equal [[:INTERVAL]], productions[:ConstInterval]
    assert_equal [[:JSON]], productions[:JsonType]
  end

  def test_numeric_type_keywords_all_have_names
    productions[:Numeric].each do |alternative|
      assert Analyzer::NUMERIC_TYPES.key?(alternative.first), "no type name for #{alternative.first}"
    end
  end

  # Functions with their own syntax are named after their first keyword.
  def test_keyword_functions_start_with_a_keyword
    [:func_expr_common_subexpr, :json_aggregate_func, :xmltable, :json_table].each do |name|
      productions[name].each do |alternative|
        refute productions.key?(alternative.first), "#{name}: #{alternative.join(" ")} does not start with a keyword"
      end
    end
  end

  # A typed literal is the only place the grammar uses func_name for a type.
  def test_func_name_users
    users = productions.select { |_, alternatives| alternatives.flatten.include?(:func_name) }.keys
    assert_equal [:AexprConst, :func_application, :tablesample_clause], users.sort
  end

  # Attribute notation (x.name as a call of name) can only arise through these.
  def test_indirection_users
    users = productions.select { |_, alternatives| alternatives.flatten.any? { |s| [:indirection, :opt_indirection].include?(s) } }.keys
    assert_equal [:c_expr, :columnref, :func_name, :indirection, :insert_column_item, :opt_indirection,
      :qualified_name, :set_target], users.sort
  end

  def test_functions_in_from_only_arise_through_table_ref
    users = productions.select { |_, alternatives| alternatives.flatten.include?(:func_table) }.keys
    assert_equal [:table_ref], users
  end

  def test_with_clause_users_are_statement_handlers
    users = productions.select { |_, alternatives| alternatives.flatten.any? { |s| [:with_clause, :opt_with_clause].include?(s) } }.keys
    (users - [:opt_with_clause]).each do |name|
      assert_equal :visit_statement, Analyzer::HANDLERS[name], "#{name} carries a WITH clause"
      productions[name].each do |alternative|
        next unless alternative.any? { |s| [:with_clause, :opt_with_clause].include?(s) }

        assert_includes [:with_clause, :opt_with_clause], alternative.first, "#{name}: WITH is not first"
      end
    end
  end

  def test_keyword_table_matches_the_grammar
    terminals = productions.values.flatten.grep(Symbol).reject { |s| productions.key?(s) }.to_set
    missing = Pgsqlarbiter::Keywords::TOKENS.values.to_set - terminals
    # Keywords that only appear in statements outside the DML subset are fine;
    # every keyword the grammar does use must be producible by the lexer.
    keyword_like = terminals.select { |t| t.to_s =~ /\A[A-Z_]+\z/ } -
      [:IDENT, :UIDENT, :FCONST, :SCONST, :USCONST, :BCONST, :XCONST, :ICONST, :PARAM, :TYPECAST, :DOT_DOT,
        :COLON_EQUALS, :EQUALS_GREATER, :LESS_EQUALS, :GREATER_EQUALS, :NOT_EQUALS,
        :FORMAT_LA, :NOT_LA, :NULLS_LA, :WITH_LA, :WITHOUT_LA, :UMINUS]
    assert_empty keyword_like.to_set - Pgsqlarbiter::Keywords::TOKENS.values.to_set
    assert_operator missing.size, :<, Pgsqlarbiter::Keywords::TOKENS.size
  end
end
