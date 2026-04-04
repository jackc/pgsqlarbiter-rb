# frozen_string_literal: true

require_relative "../test_helper"

class TestVerdict < Minitest::Test
  # ====================================================================
  # Arbiter#judge — allowed queries
  # ====================================================================

  def test_allowed_query_returns_allowed_verdict
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["count"]
    )
    verdict = arbiter.judge("SELECT count(*) FROM users")
    assert verdict.allowed?
    assert verdict.statement_type_allowed?
    assert_equal :select, verdict.statement_type
    assert_empty verdict.disallowed_tables
    assert_empty verdict.disallowed_functions
    assert_empty verdict.reasons
  end

  # ====================================================================
  # Arbiter#judge — statement type denial
  # ====================================================================

  def test_denied_statement_type
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("INSERT INTO users (name) VALUES ('alice')")
    refute verdict.allowed?
    refute verdict.statement_type_allowed?
    assert_equal :insert, verdict.statement_type
    assert_includes verdict.reasons, "statement type :insert is not allowed"
  end

  # ====================================================================
  # Arbiter#judge — table denial
  # ====================================================================

  def test_disallowed_table
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("SELECT * FROM orders")
    refute verdict.allowed?
    assert verdict.statement_type_allowed?
    assert_equal ["orders"], verdict.disallowed_tables
    assert_includes verdict.reasons, "table \"orders\" is not allowed"
  end

  def test_multiple_disallowed_tables
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("SELECT * FROM orders JOIN products ON orders.product_id = products.id")
    refute verdict.allowed?
    assert_equal ["orders", "products"], verdict.disallowed_tables
  end

  def test_mix_of_allowed_and_disallowed_tables
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("SELECT * FROM users JOIN orders ON users.id = orders.user_id")
    refute verdict.allowed?
    assert_equal ["orders"], verdict.disallowed_tables
  end

  # ====================================================================
  # Arbiter#judge — function denial
  # ====================================================================

  def test_disallowed_function
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["sum"]
    )
    verdict = arbiter.judge("SELECT count(*) FROM users")
    refute verdict.allowed?
    assert_empty verdict.disallowed_tables
    assert_equal ["count"], verdict.disallowed_functions
    assert_includes verdict.reasons, "function \"count\" is not allowed"
  end

  # ====================================================================
  # Arbiter#judge — multiple simultaneous violations
  # ====================================================================

  def test_all_three_violations
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["count"]
    )
    verdict = arbiter.judge("INSERT INTO orders (total) VALUES (pg_sleep(1))")
    refute verdict.allowed?
    refute verdict.statement_type_allowed?
    assert_equal ["orders"], verdict.disallowed_tables
    assert_equal ["pg_sleep"], verdict.disallowed_functions
    assert_equal 3, verdict.reasons.length
  end

  # ====================================================================
  # Arbiter#judge — reasons format
  # ====================================================================

  def test_reasons_empty_when_allowed
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("SELECT * FROM users")
    assert_equal [], verdict.reasons
  end

  def test_reasons_frozen
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    verdict = arbiter.judge("SELECT * FROM orders")
    assert verdict.reasons.frozen?
  end

  # ====================================================================
  # Arbiter#judge — error propagation
  # ====================================================================

  def test_ddl_raises_disallowed_statement_error
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    assert_raises(Pgsqlarbiter::DisallowedStatementError) do
      arbiter.judge("DROP TABLE users")
    end
  end

  def test_multiple_statements_raises
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    assert_raises(Pgsqlarbiter::MultipleStatementsError) do
      arbiter.judge("SELECT 1; SELECT 2")
    end
  end

  # ====================================================================
  # Module-level Pgsqlarbiter.judge
  # ====================================================================

  def test_module_judge_allowed
    verdict = Pgsqlarbiter.judge("SELECT * FROM users", tables: ["users"])
    assert verdict.allowed?
  end

  def test_module_judge_denied
    verdict = Pgsqlarbiter.judge("SELECT * FROM secrets", tables: ["users"])
    refute verdict.allowed?
    assert_equal ["secrets"], verdict.disallowed_tables
  end

  def test_module_judge_with_statement_types
    verdict = Pgsqlarbiter.judge(
      "INSERT INTO users (name) VALUES ('alice')",
      tables: ["users"],
      statement_types: [:select, :insert]
    )
    assert verdict.allowed?
  end

  def test_module_judge_with_custom_functions
    verdict = Pgsqlarbiter.judge(
      "SELECT my_func(id) FROM users",
      tables: ["users"],
      functions: ["my_func"]
    )
    assert verdict.allowed?
  end
end
