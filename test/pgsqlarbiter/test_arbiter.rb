# frozen_string_literal: true

require_relative "../test_helper"

class TestArbiter < Minitest::Test
  # ====================================================================
  # Construction
  # ====================================================================

  def test_valid_statement_types_accepted
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select, :insert, :update, :delete, :merge, :values],
      tables: ["users"]
    )
    assert_equal Set[:select, :insert, :update, :delete, :merge, :values], arbiter.statement_types
  end

  def test_unknown_statement_type_raises_argument_error
    error = assert_raises(ArgumentError) do
      Pgsqlarbiter::Arbiter.new(statement_types: [:select, :drop], tables: ["users"])
    end
    assert_includes error.message, ":drop"
  end

  def test_empty_statement_types_allowed
    arbiter = Pgsqlarbiter::Arbiter.new(statement_types: [], tables: ["users"])
    assert_equal Set[], arbiter.statement_types
  end

  def test_functions_default_to_safe_functions
    arbiter = Pgsqlarbiter::Arbiter.new(statement_types: [:select], tables: ["users"])
    assert_equal Pgsqlarbiter::SAFE_FUNCTIONS, arbiter.functions
  end

  def test_custom_functions
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["count", "sum"]
    )
    assert_equal Set["count", "sum"], arbiter.functions
  end

  # ====================================================================
  # Statement type checks
  # ====================================================================

  def test_select_allowed_when_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    assert arbiter.allow?("SELECT * FROM users")
  end

  def test_select_denied_when_not_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:insert],
      tables: ["users"]
    )
    refute arbiter.allow?("SELECT * FROM users")
  end

  def test_insert_denied_when_only_select_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    refute arbiter.allow?("INSERT INTO users (name) VALUES ('alice')")
  end

  def test_insert_allowed_when_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:insert],
      tables: ["users"]
    )
    assert arbiter.allow?("INSERT INTO users (name) VALUES ('alice')")
  end

  def test_update_allowed_when_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:update],
      tables: ["users"]
    )
    assert arbiter.allow?("UPDATE users SET name = 'bob' WHERE id = 1")
  end

  def test_delete_allowed_when_configured
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:delete],
      tables: ["users"]
    )
    assert arbiter.allow?("DELETE FROM users WHERE id = 1")
  end

  def test_empty_statement_types_denies_everything
    arbiter = Pgsqlarbiter::Arbiter.new(statement_types: [], tables: ["users"])
    refute arbiter.allow?("SELECT * FROM users")
  end

  # ====================================================================
  # Table checks
  # ====================================================================

  def test_allowed_table_passes
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    assert arbiter.allow?("SELECT * FROM users")
  end

  def test_disallowed_table_fails
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    refute arbiter.allow?("SELECT * FROM orders")
  end

  def test_multiple_tables_all_must_be_allowed
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    refute arbiter.allow?("SELECT * FROM users JOIN orders ON users.id = orders.user_id")
  end

  def test_multiple_tables_all_allowed
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users", "orders"]
    )
    assert arbiter.allow?("SELECT * FROM users JOIN orders ON users.id = orders.user_id")
  end

  # ====================================================================
  # Function checks
  # ====================================================================

  def test_allowed_function_passes
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["count"]
    )
    assert arbiter.allow?("SELECT count(*) FROM users")
  end

  def test_disallowed_function_fails
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["sum"]
    )
    refute arbiter.allow?("SELECT count(*) FROM users")
  end

  # ====================================================================
  # All three dimensions must pass
  # ====================================================================

  def test_correct_type_and_table_but_wrong_function
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["sum"]
    )
    refute arbiter.allow?("SELECT count(*) FROM users")
  end

  def test_correct_type_and_function_but_wrong_table
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["orders"],
      functions: ["count"]
    )
    refute arbiter.allow?("SELECT count(*) FROM users")
  end

  def test_correct_table_and_function_but_wrong_type
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:insert],
      tables: ["users"],
      functions: ["count"]
    )
    refute arbiter.allow?("SELECT count(*) FROM users")
  end

  def test_all_three_pass
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"],
      functions: ["count"]
    )
    assert arbiter.allow?("SELECT count(*) FROM users")
  end

  # ====================================================================
  # Error propagation
  # ====================================================================

  def test_ddl_raises_disallowed_statement_error
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select, :insert, :update, :delete],
      tables: ["users"]
    )
    assert_raises(Pgsqlarbiter::DisallowedStatementError) do
      arbiter.allow?("DROP TABLE users")
    end
  end

  def test_multiple_statements_raises
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users"]
    )
    assert_raises(Pgsqlarbiter::MultipleStatementsError) do
      arbiter.allow?("SELECT 1; SELECT 2")
    end
  end

  # ====================================================================
  # CTE handling
  # ====================================================================

  def test_cte_select_allowed_with_select_type
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:select],
      tables: ["users", "orders"]
    )
    assert arbiter.allow?(<<~SQL)
      WITH recent AS (SELECT * FROM orders)
      SELECT * FROM users JOIN recent ON users.id = recent.user_id
    SQL
  end

  def test_cte_select_denied_without_select_type
    arbiter = Pgsqlarbiter::Arbiter.new(
      statement_types: [:insert],
      tables: ["users", "orders"]
    )
    refute arbiter.allow?(<<~SQL)
      WITH recent AS (SELECT * FROM orders)
      SELECT * FROM users JOIN recent ON users.id = recent.user_id
    SQL
  end
end
