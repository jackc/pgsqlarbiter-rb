# frozen_string_literal: true

require_relative "../test_helper"

class TestIntegration < Minitest::Test
  def analyze(sql)
    Pgsqlarbiter.analyze(sql)
  end

  # ====================================================================
  # Complex realistic queries
  # ====================================================================

  def test_multi_join_with_subquery_and_cte
    result = analyze(<<~SQL)
      WITH recent AS (SELECT * FROM orders WHERE date > '2024-01-01')
      SELECT u.name, r.total
      FROM users u
      JOIN recent r ON u.id = r.user_id
      LEFT JOIN (SELECT * FROM addresses) a ON u.id = a.user_id
      WHERE u.active = true
    SQL
    assert_includes result.tables, "orders"
    assert_includes result.tables, "users"
    assert_includes result.tables, "addresses"
    refute_includes result.tables, "recent"
    refute_includes result.tables, "u"
    refute_includes result.tables, "r"
    refute_includes result.tables, "a"
    assert_equal :select, result.statement_type
  end

  def test_insert_with_subquery
    result = analyze("INSERT INTO archive SELECT * FROM logs WHERE date < '2024-01-01'")
    assert_includes result.tables, "archive"
    assert_includes result.tables, "logs"
    assert_equal :insert, result.statement_type
  end

  def test_update_with_from_and_functions
    result = analyze(<<~SQL)
      UPDATE products SET price = round(base_price * 1.1, 2)
      FROM categories
      WHERE products.cat_id = categories.id
    SQL
    assert_includes result.tables, "products"
    assert_includes result.tables, "categories"
    assert_includes result.functions, "round"
    assert_equal :update, result.statement_type
  end

  def test_delete_with_using
    result = analyze(<<~SQL)
      DELETE FROM orders
      USING customers
      WHERE orders.customer_id = customers.id AND customers.deleted = true
    SQL
    assert_includes result.tables, "orders"
    assert_includes result.tables, "customers"
    assert_equal :delete, result.statement_type
  end

  def test_merge_with_subquery_source
    result = analyze(<<~SQL)
      MERGE INTO inventory t
      USING (SELECT product_id, sum(quantity) as qty FROM shipments GROUP BY product_id) s
      ON t.product_id = s.product_id
      WHEN MATCHED THEN UPDATE SET quantity = t.quantity + s.qty
      WHEN NOT MATCHED THEN INSERT (product_id, quantity) VALUES (s.product_id, s.qty)
    SQL
    assert_includes result.tables, "inventory"
    assert_includes result.tables, "shipments"
    assert_includes result.functions, "sum"
    refute_includes result.tables, "s"
    assert_equal :merge, result.statement_type
  end

  def test_multiple_ctes_with_joins
    result = analyze(<<~SQL)
      WITH
        active_users AS (SELECT * FROM users WHERE active = true),
        recent_orders AS (SELECT * FROM orders WHERE date > '2024-01-01')
      SELECT u.name, o.total
      FROM active_users u
      JOIN recent_orders o ON u.id = o.user_id
      LEFT JOIN addresses a ON u.id = a.user_id
    SQL
    assert_includes result.tables, "users"
    assert_includes result.tables, "orders"
    assert_includes result.tables, "addresses"
    refute_includes result.tables, "active_users"
    refute_includes result.tables, "recent_orders"
  end

  def test_complex_select_with_many_functions
    result = analyze(<<~SQL)
      SELECT
        count(*) AS total,
        sum(amount) AS total_amount,
        avg(amount) AS avg_amount,
        coalesce(name, 'Unknown') AS display_name,
        extract(year FROM created_at) AS year
      FROM transactions t
      JOIN accounts a ON t.account_id = a.id
      WHERE a.status = 'active'
      GROUP BY a.name, extract(year FROM created_at)
    SQL
    assert_includes result.tables, "transactions"
    assert_includes result.tables, "accounts"
    assert_includes result.functions, "count"
    assert_includes result.functions, "sum"
    assert_includes result.functions, "avg"
    assert_includes result.functions, "coalesce"
    assert_includes result.functions, "extract"
    refute_includes result.tables, "t"
    refute_includes result.tables, "a"
  end

  def test_deeply_nested_subqueries
    result = analyze(<<~SQL)
      SELECT * FROM (
        SELECT * FROM (
          SELECT * FROM (
            SELECT id, name FROM deep_table
          ) level1
        ) level2
      ) level3
    SQL
    assert_equal ["deep_table"], result.tables
  end

  def test_select_with_scalar_subqueries
    result = analyze(<<~SQL)
      SELECT
        u.name,
        (SELECT count(*) FROM orders o WHERE o.user_id = u.id) AS order_count,
        (SELECT max(date) FROM orders o WHERE o.user_id = u.id) AS last_order
      FROM users u
    SQL
    assert_includes result.tables, "users"
    assert_includes result.tables, "orders"
    assert_includes result.functions, "count"
    assert_includes result.functions, "max"
  end

  def test_union_query
    result = analyze(<<~SQL)
      SELECT id, name FROM active_users
      UNION ALL
      SELECT id, name FROM archived_users
    SQL
    assert_includes result.tables, "active_users"
    assert_includes result.tables, "archived_users"
  end

  def test_insert_with_returning
    result = analyze(<<~SQL)
      INSERT INTO audit_log (action, user_id)
      SELECT 'login', id FROM users WHERE last_login > now() - interval '1 day'
      RETURNING id
    SQL
    assert_includes result.tables, "audit_log"
    assert_includes result.tables, "users"
    assert_includes result.functions, "now"
  end

  # ====================================================================
  # Known attack vectors — all rejected or detected
  # ====================================================================

  def test_attack_show_server_version
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SHOW server_version") }
  end

  def test_attack_set_statement_timeout
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SET statement_timeout = 0") }
  end

  def test_attack_information_schema_detected
    result = analyze("SELECT * FROM information_schema.tables")
    assert_includes result.tables, "information_schema.tables"
  end

  def test_attack_pg_catalog_detected
    result = analyze("SELECT * FROM pg_catalog.pg_class")
    assert_includes result.tables, "pg_catalog.pg_class"
  end

  def test_attack_set_config_detected
    result = analyze("SELECT set_config('statement_timeout', '0', false)")
    assert_includes result.functions, "set_config"
  end

  def test_attack_pg_sleep_detected
    result = analyze("SELECT pg_sleep(10)")
    assert_includes result.functions, "pg_sleep"
  end

  def test_attack_lo_import_detected
    result = analyze("SELECT lo_import('/etc/passwd')")
    assert_includes result.functions, "lo_import"
  end

  def test_attack_pg_advisory_lock_detected
    result = analyze("SELECT pg_advisory_lock(1)")
    assert_includes result.functions, "pg_advisory_lock"
  end

  def test_attack_pg_notify_detected
    result = analyze("SELECT pg_notify('channel', 'payload')")
    assert_includes result.functions, "pg_notify"
  end

  def test_attack_begin_transaction
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("BEGIN") }
  end

  def test_attack_multi_statement_with_drop
    assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("SELECT 1; DROP TABLE users") }
  end

  def test_attack_multi_statement_disguised
    assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("SELECT 1; DELETE FROM users") }
  end

  def test_attack_schema_qualified_dangerous_function
    result = analyze("SELECT pg_catalog.set_config('statement_timeout', '0', false)")
    assert_includes result.functions, "pg_catalog.set_config"
  end

  # ====================================================================
  # Whitelist convenience method
  # ====================================================================

  def test_allowed_simple
    assert Pgsqlarbiter.allow?("SELECT * FROM users", tables: ["users"], functions: [])
  end

  def test_not_allowed_missing_table
    refute Pgsqlarbiter.allow?("SELECT * FROM users", tables: ["other"], functions: [])
  end

  def test_allowed_with_function
    assert Pgsqlarbiter.allow?("SELECT count(*) FROM users", tables: ["users"], functions: ["count"])
  end

  def test_not_allowed_missing_function
    refute Pgsqlarbiter.allow?("SELECT count(*) FROM users", tables: ["users"], functions: [])
  end

  def test_allowed_complex_query
    assert Pgsqlarbiter.allow?(
      "SELECT u.name, count(*) FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.name",
      tables: ["users", "orders"],
      functions: ["count"]
    )
  end

  def test_not_allowed_extra_table
    refute Pgsqlarbiter.allow?(
      "SELECT * FROM users JOIN secrets ON users.id = secrets.user_id",
      tables: ["users"],
      functions: []
    )
  end

  def test_allowed_rejects_disallowed_statement
    assert_raises(Pgsqlarbiter::DisallowedStatementError) do
      Pgsqlarbiter.allow?("DROP TABLE users", tables: ["users"], functions: [])
    end
  end

  def test_allowed_rejects_multiple_statements
    assert_raises(Pgsqlarbiter::MultipleStatementsError) do
      Pgsqlarbiter.allow?("SELECT 1; SELECT 2", tables: [], functions: [])
    end
  end

  # ====================================================================
  # Edge cases in realistic queries
  # ====================================================================

  def test_select_with_cast_and_typecast
    result = analyze("SELECT CAST(price AS numeric), amount::int FROM products")
    assert_equal ["products"], result.tables
    refute_includes result.functions, "cast"
  end

  def test_select_with_case_expression
    result = analyze(<<~SQL)
      SELECT CASE WHEN status = 'active' THEN 'yes' ELSE 'no' END
      FROM users
    SQL
    assert_equal ["users"], result.tables
    refute_includes result.functions, "case"
  end

  def test_select_with_exists_subquery
    result = analyze(<<~SQL)
      SELECT * FROM products p
      WHERE EXISTS (SELECT 1 FROM inventory i WHERE i.product_id = p.id AND i.quantity > 0)
    SQL
    assert_includes result.tables, "products"
    assert_includes result.tables, "inventory"
    refute_includes result.functions, "exists"
  end

  def test_select_with_in_subquery
    result = analyze(<<~SQL)
      SELECT * FROM users
      WHERE id IN (SELECT user_id FROM active_sessions)
    SQL
    assert_includes result.tables, "users"
    assert_includes result.tables, "active_sessions"
  end

  def test_values_with_function_calls
    result = analyze("VALUES (1, now()), (2, current_timestamp)")
    assert_includes result.functions, "now"
    assert_equal :values, result.statement_type
  end

  def test_query_with_comments
    result = analyze(<<~SQL)
      -- Fetch active users
      SELECT * /* all columns */ FROM users
      WHERE active = true -- only active ones
    SQL
    assert_equal ["users"], result.tables
  end

  def test_query_with_dollar_quoted_strings
    result = analyze("SELECT $$this has 'quotes' and ; semicolons$$ FROM config")
    assert_equal ["config"], result.tables
  end

  def test_query_with_mixed_quoting
    result = analyze(<<~SQL)
      SELECT "Column Name", 'literal', E'escape\\n'
      FROM "Schema"."Table"
      WHERE "Column Name" = $1
    SQL
    assert_equal ["Schema.Table"], result.tables
  end

  def test_delete_from_only_with_using
    result = analyze(<<~SQL)
      DELETE FROM ONLY parent_table
      USING child_table
      WHERE parent_table.id = child_table.parent_id
    SQL
    assert_includes result.tables, "parent_table"
    assert_includes result.tables, "child_table"
  end

  def test_update_with_multiple_from_tables
    result = analyze(<<~SQL)
      UPDATE target t
      SET value = s1.value + s2.value
      FROM source1 s1, source2 s2
      WHERE t.id = s1.id AND t.id = s2.id
    SQL
    assert_includes result.tables, "target"
    assert_includes result.tables, "source1"
    assert_includes result.tables, "source2"
  end

  def test_lateral_join
    result = analyze(<<~SQL)
      SELECT u.*, recent.*
      FROM users u,
      LATERAL (SELECT * FROM orders o WHERE o.user_id = u.id ORDER BY date DESC LIMIT 5) recent
    SQL
    assert_includes result.tables, "users"
    assert_includes result.tables, "orders"
  end

  def test_recursive_cte
    result = analyze(<<~SQL)
      WITH RECURSIVE subordinates AS (
        SELECT id, name, manager_id FROM employees WHERE id = 1
        UNION ALL
        SELECT e.id, e.name, e.manager_id
        FROM employees e
        JOIN subordinates s ON e.manager_id = s.id
      )
      SELECT * FROM subordinates
    SQL
    assert_includes result.tables, "employees"
    refute_includes result.tables, "subordinates"
  end

  def test_extract_from_does_not_pollute_tables
    result = analyze(<<~SQL)
      SELECT
        extract(year FROM created_at) AS year,
        extract(month FROM created_at) AS month,
        count(*)
      FROM events
      GROUP BY 1, 2
    SQL
    assert_equal ["events"], result.tables
    assert_includes result.functions, "extract"
    assert_includes result.functions, "count"
    # "created_at" should NOT appear as a table
    refute_includes result.tables, "created_at"
  end

  def test_trim_from_does_not_pollute_tables
    result = analyze(<<~SQL)
      SELECT trim(both ' ' FROM name)
      FROM contacts
    SQL
    assert_equal ["contacts"], result.tables
    assert_includes result.functions, "trim"
    refute_includes result.tables, "name"
  end

  def test_insert_on_conflict
    result = analyze(<<~SQL)
      INSERT INTO metrics (key, value)
      VALUES ('page_views', 1)
      ON CONFLICT (key) DO UPDATE SET value = metrics.value + 1
    SQL
    assert_equal ["metrics"], result.tables
  end

  def test_select_with_window_function
    result = analyze(<<~SQL)
      SELECT
        name,
        row_number() OVER (PARTITION BY department ORDER BY salary DESC) as rank
      FROM employees
    SQL
    assert_includes result.tables, "employees"
    assert_includes result.functions, "row_number"
  end

  def test_select_with_filter_clause
    result = analyze(<<~SQL)
      SELECT
        count(*) FILTER (WHERE status = 'active') AS active_count,
        count(*) FILTER (WHERE status = 'inactive') AS inactive_count
      FROM users
    SQL
    assert_includes result.tables, "users"
    assert_includes result.functions, "count"
  end

  def test_comma_separated_from_after_subquery
    result = analyze(<<~SQL)
      SELECT * FROM (SELECT id FROM inner_t) sub, other_table
    SQL
    assert_includes result.tables, "inner_t"
    assert_includes result.tables, "other_table"
  end

  def test_table_valued_function_with_alias_columns
    result = analyze(<<~SQL)
      SELECT * FROM generate_series(1, 10) AS g(n)
    SQL
    assert_includes result.functions, "generate_series"
    refute_includes result.tables, "generate_series"
    refute_includes result.functions, "g"
  end
end
