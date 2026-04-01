# frozen_string_literal: true

require_relative "../test_helper"

class TestAnalyzer < Minitest::Test
  def analyze(sql)
    Pgsqlarbiter.analyze(sql)
  end

  # ====================================================================
  # Statement type detection — allowed
  # ====================================================================

  def test_select_literal
    assert_equal :select, analyze("SELECT 1").statement_type
  end

  def test_select_from
    assert_equal :select, analyze("SELECT * FROM t").statement_type
  end

  def test_insert_into_values
    assert_equal :insert, analyze("INSERT INTO t VALUES (1)").statement_type
  end

  def test_insert_into_select
    assert_equal :insert, analyze("INSERT INTO t SELECT * FROM s").statement_type
  end

  def test_update
    assert_equal :update, analyze("UPDATE t SET x = 1").statement_type
  end

  def test_delete
    assert_equal :delete, analyze("DELETE FROM t").statement_type
  end

  def test_delete_with_where
    assert_equal :delete, analyze("DELETE FROM t WHERE id = 1").statement_type
  end

  def test_merge
    assert_equal :merge, analyze("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET x = s.x").statement_type
  end

  def test_values_standalone
    assert_equal :values, analyze("VALUES (1, 'a'), (2, 'b')").statement_type
  end

  def test_with_select
    assert_equal :select, analyze("WITH cte AS (SELECT 1) SELECT * FROM cte").statement_type
  end

  def test_with_recursive_select
    assert_equal :select, analyze("WITH RECURSIVE cte AS (SELECT 1 UNION ALL SELECT x + 1 FROM cte WHERE x < 10) SELECT * FROM cte").statement_type
  end

  def test_with_insert
    assert_equal :insert, analyze("WITH cte AS (SELECT 1) INSERT INTO t SELECT * FROM cte").statement_type
  end

  def test_with_update
    assert_equal :update, analyze("WITH cte AS (SELECT 1) UPDATE t SET x = (SELECT * FROM cte)").statement_type
  end

  def test_with_delete
    assert_equal :delete, analyze("WITH cte AS (SELECT 1) DELETE FROM t WHERE id IN (SELECT * FROM cte)").statement_type
  end

  # ====================================================================
  # Statement type detection — rejected (DisallowedStatementError)
  # ====================================================================

  def test_reject_create_table
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("CREATE TABLE t (id int)") }
  end

  def test_reject_drop_table
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("DROP TABLE t") }
  end

  def test_reject_alter_table
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("ALTER TABLE t ADD COLUMN x int") }
  end

  def test_reject_truncate
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("TRUNCATE t") }
  end

  def test_reject_grant
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("GRANT SELECT ON t TO myuser") }
  end

  def test_reject_revoke
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("REVOKE SELECT ON t FROM myuser") }
  end

  def test_reject_show
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SHOW server_version") }
  end

  def test_reject_set
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SET statement_timeout = 0") }
  end

  def test_reject_reset
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("RESET statement_timeout") }
  end

  def test_reject_begin
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("BEGIN") }
  end

  def test_reject_start_transaction
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("START TRANSACTION") }
  end

  def test_reject_commit
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("COMMIT") }
  end

  def test_reject_rollback
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("ROLLBACK") }
  end

  def test_reject_savepoint
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SAVEPOINT sp1") }
  end

  def test_reject_release
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("RELEASE SAVEPOINT sp1") }
  end

  def test_reject_prepare
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("PREPARE stmt AS SELECT 1") }
  end

  def test_reject_execute
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("EXECUTE stmt") }
  end

  def test_reject_deallocate
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("DEALLOCATE stmt") }
  end

  def test_reject_listen
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("LISTEN channel") }
  end

  def test_reject_notify
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("NOTIFY channel") }
  end

  def test_reject_unlisten
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("UNLISTEN channel") }
  end

  def test_reject_copy
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("COPY t FROM STDIN") }
  end

  def test_reject_vacuum
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("VACUUM t") }
  end

  def test_reject_analyze
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("ANALYZE t") }
  end

  def test_reject_cluster
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("CLUSTER t") }
  end

  def test_reject_reindex
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("REINDEX TABLE t") }
  end

  def test_reject_lock
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("LOCK TABLE t") }
  end

  def test_reject_discard
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("DISCARD ALL") }
  end

  def test_reject_explain
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("EXPLAIN SELECT 1") }
  end

  def test_reject_do
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("DO $$ BEGIN END $$") }
  end

  def test_reject_call
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("CALL my_proc()") }
  end

  # ====================================================================
  # Multiple statement rejection
  # ====================================================================

  def test_reject_multiple_selects
    assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("SELECT 1; SELECT 2") }
  end

  def test_reject_select_then_drop
    assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("SELECT 1; DROP TABLE t") }
  end

  def test_reject_insert_then_delete
    assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("INSERT INTO t VALUES (1); DELETE FROM t") }
  end

  def test_trailing_semicolon_allowed
    result = analyze("SELECT 1;")
    assert_equal :select, result.statement_type
  end

  def test_multiple_trailing_semicolons_allowed
    result = analyze("SELECT 1;;")
    assert_equal :select, result.statement_type
  end

  # ====================================================================
  # Empty/blank input
  # ====================================================================

  def test_empty_input
    assert_raises(Pgsqlarbiter::ParseError) { analyze("") }
  end

  def test_whitespace_only
    assert_raises(Pgsqlarbiter::ParseError) { analyze("   ") }
  end

  def test_comment_only
    assert_raises(Pgsqlarbiter::ParseError) { analyze("-- just a comment") }
  end

  # ====================================================================
  # Table extraction — FROM clause
  # ====================================================================

  def test_from_simple_table
    assert_equal ["users"], analyze("SELECT * FROM users").tables
  end

  def test_from_schema_qualified
    assert_equal ["schema_name.users"], analyze("SELECT * FROM schema_name.users").tables
  end

  def test_from_quoted_table
    assert_equal ["MyTable"], analyze('SELECT * FROM "MyTable"').tables
  end

  def test_from_quoted_schema_and_table
    assert_equal ["schema.Table"], analyze('SELECT * FROM "schema"."Table"').tables
  end

  def test_from_alias_bare
    result = analyze("SELECT * FROM users u")
    assert_equal ["users"], result.tables
  end

  def test_from_alias_explicit
    result = analyze("SELECT * FROM users AS u")
    assert_equal ["users"], result.tables
  end

  def test_from_comma_separated
    assert_equal ["a", "b", "c"], analyze("SELECT * FROM a, b, c").tables
  end

  def test_from_comma_with_join
    tables = analyze("SELECT * FROM a, b JOIN c ON b.id = c.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
    assert_includes tables, "c"
  end

  # ====================================================================
  # Table extraction — JOIN variants
  # ====================================================================

  def test_join
    tables = analyze("SELECT * FROM a JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_inner_join
    tables = analyze("SELECT * FROM a INNER JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_left_join
    tables = analyze("SELECT * FROM a LEFT JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_left_outer_join
    tables = analyze("SELECT * FROM a LEFT OUTER JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_right_join
    tables = analyze("SELECT * FROM a RIGHT JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_full_join
    tables = analyze("SELECT * FROM a FULL JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_full_outer_join
    tables = analyze("SELECT * FROM a FULL OUTER JOIN b ON a.id = b.id").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_cross_join
    tables = analyze("SELECT * FROM a CROSS JOIN b").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_natural_join
    tables = analyze("SELECT * FROM a NATURAL JOIN b").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
  end

  def test_multiple_joins
    tables = analyze("SELECT * FROM a JOIN b ON a.id = b.id LEFT JOIN c ON a.id = c.id CROSS JOIN d").tables
    assert_includes tables, "a"
    assert_includes tables, "b"
    assert_includes tables, "c"
    assert_includes tables, "d"
  end

  # ====================================================================
  # Table extraction — INSERT
  # ====================================================================

  def test_insert_into_target
    assert_equal ["target"], analyze("INSERT INTO target VALUES (1)").tables
  end

  def test_insert_into_schema_qualified
    assert_equal ["schema.target"], analyze("INSERT INTO schema.target VALUES (1)").tables
  end

  def test_insert_into_select_tables
    tables = analyze("INSERT INTO target SELECT * FROM source").tables
    assert_includes tables, "target"
    assert_includes tables, "source"
  end

  # ====================================================================
  # Table extraction — UPDATE
  # ====================================================================

  def test_update_target
    assert_equal ["t"], analyze("UPDATE t SET x = 1").tables
  end

  def test_update_schema_qualified
    assert_equal ["schema.t"], analyze("UPDATE schema.t SET x = 1").tables
  end

  def test_update_with_from
    tables = analyze("UPDATE t SET x = s.x FROM source s WHERE t.id = s.id").tables
    assert_includes tables, "t"
    assert_includes tables, "source"
  end

  # ====================================================================
  # Table extraction — DELETE
  # ====================================================================

  def test_delete_target
    assert_equal ["target"], analyze("DELETE FROM target").tables
  end

  def test_delete_schema_qualified
    assert_equal ["schema.target"], analyze("DELETE FROM schema.target WHERE id = 1").tables
  end

  def test_delete_using
    tables = analyze("DELETE FROM target USING source WHERE target.id = source.id").tables
    assert_includes tables, "target"
    assert_includes tables, "source"
  end

  # ====================================================================
  # Table extraction — MERGE
  # ====================================================================

  def test_merge_into_using
    tables = analyze("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE").tables
    assert_includes tables, "t"
    assert_includes tables, "s"
  end

  def test_merge_with_subquery_using
    tables = analyze("MERGE INTO t USING (SELECT * FROM s) AS sub ON t.id = sub.id WHEN MATCHED THEN DELETE").tables
    assert_includes tables, "t"
    assert_includes tables, "s"
  end

  # ====================================================================
  # Table extraction — ONLY keyword
  # ====================================================================

  def test_select_from_only
    assert_equal ["parent_table"], analyze("SELECT * FROM ONLY parent_table").tables
  end

  def test_update_only
    assert_equal ["parent"], analyze("UPDATE ONLY parent SET x = 1").tables
  end

  def test_delete_from_only
    assert_equal ["parent"], analyze("DELETE FROM ONLY parent WHERE id = 1").tables
  end

  # ====================================================================
  # Table extraction — subqueries (NOT extracted as tables)
  # ====================================================================

  def test_subquery_not_extracted
    assert_equal [], analyze("SELECT * FROM (SELECT 1) sub").tables
  end

  def test_subquery_inner_table_extracted
    assert_equal ["inner_t"], analyze("SELECT * FROM (SELECT * FROM inner_t) sub").tables
  end

  def test_nested_subquery
    assert_equal ["deep"], analyze("SELECT * FROM (SELECT * FROM (SELECT * FROM deep) s1) s2").tables
  end

  def test_subquery_in_where_in
    tables = analyze("SELECT * FROM t WHERE id IN (SELECT id FROM s)").tables
    assert_includes tables, "t"
    assert_includes tables, "s"
  end

  def test_subquery_in_where_exists
    tables = analyze("SELECT * FROM t WHERE EXISTS (SELECT 1 FROM s)").tables
    assert_includes tables, "t"
    assert_includes tables, "s"
  end

  # ====================================================================
  # Table extraction — CTEs (CTE names NOT extracted)
  # ====================================================================

  def test_cte_name_not_extracted
    result = analyze("WITH cte AS (SELECT * FROM t) SELECT * FROM cte")
    assert_equal ["t"], result.tables
  end

  def test_multiple_ctes
    result = analyze("WITH c1 AS (SELECT * FROM t1), c2 AS (SELECT * FROM t2) SELECT * FROM c1 JOIN c2 ON c1.id = c2.id")
    assert_includes result.tables, "t1"
    assert_includes result.tables, "t2"
    refute_includes result.tables, "c1"
    refute_includes result.tables, "c2"
  end

  def test_recursive_cte
    result = analyze("WITH RECURSIVE cte AS (SELECT * FROM t UNION ALL SELECT * FROM cte JOIN t ON cte.pid = t.id) SELECT * FROM cte")
    assert_includes result.tables, "t"
    refute_includes result.tables, "cte"
  end

  # ====================================================================
  # Table extraction — LATERAL
  # ====================================================================

  def test_lateral_subquery
    tables = analyze("SELECT * FROM t, LATERAL (SELECT * FROM s WHERE s.id = t.id) sub").tables
    assert_includes tables, "t"
    assert_includes tables, "s"
  end

  # ====================================================================
  # Table extraction — quoted identifiers as table names
  # ====================================================================

  def test_quoted_keyword_as_table_name
    assert_equal ["select"], analyze('SELECT * FROM "select"').tables
  end

  def test_quoted_from_as_table_name
    assert_equal ["FROM"], analyze('SELECT * FROM "FROM"').tables
  end

  # ====================================================================
  # Quoted identifiers with spaces (supported)
  # ====================================================================

  def test_quoted_table_with_space
    assert_equal ["my table"], analyze('SELECT * FROM "my table"').tables
  end

  def test_quoted_schema_and_table_with_spaces
    assert_equal ["my schema.my table"], analyze('SELECT * FROM "my schema"."my table"').tables
  end

  def test_quoted_table_with_space_and_alias
    assert_equal ["my table"], analyze('SELECT * FROM "my table" AS t').tables
  end

  def test_quoted_function_with_space
    result = analyze('SELECT "my func"(1)')
    assert_includes result.functions, "my func"
  end

  def test_whitelist_with_spaced_identifiers
    assert Pgsqlarbiter.allow?(
      'SELECT * FROM "my schema"."my table"',
      tables: ["my schema.my table"],
      functions: []
    )
  end

  # ====================================================================
  # Quoted identifiers with dots (rejected — ambiguous representation)
  # ====================================================================

  def test_reject_quoted_table_with_dot
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT * FROM "my.table"') }
  end

  def test_reject_quoted_schema_qualified_table_with_dot
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT * FROM schema."my.table"') }
  end

  def test_reject_quoted_function_with_dot
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT "my.func"(1)') }
  end

  def test_reject_quoted_schema_with_dot
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT * FROM "my.schema".table_name') }
  end

  # ====================================================================
  # Function extraction — basic
  # ====================================================================

  def test_function_count
    result = analyze("SELECT count(*) FROM t")
    assert_includes result.functions, "count"
  end

  def test_function_multiple
    result = analyze("SELECT sum(x), avg(y) FROM t")
    assert_includes result.functions, "sum"
    assert_includes result.functions, "avg"
  end

  def test_function_upper
    result = analyze("SELECT upper(name) FROM t")
    assert_includes result.functions, "upper"
  end

  # ====================================================================
  # Function extraction — schema-qualified
  # ====================================================================

  def test_function_schema_qualified
    result = analyze("SELECT schema.my_func(1)")
    assert_includes result.functions, "schema.my_func"
  end

  def test_function_pg_catalog_set_config
    result = analyze("SELECT pg_catalog.set_config('x', 'y', false)")
    assert_includes result.functions, "pg_catalog.set_config"
  end

  # ====================================================================
  # Function extraction — table-valued functions in FROM
  # ====================================================================

  def test_table_valued_function
    result = analyze("SELECT * FROM generate_series(1, 10)")
    assert_includes result.functions, "generate_series"
    refute_includes result.tables, "generate_series"
  end

  def test_table_valued_function_schema_qualified
    result = analyze("SELECT * FROM schema.my_func(42) AS t(id, name)")
    assert_includes result.functions, "schema.my_func"
    refute_includes result.tables, "schema.my_func"
  end

  # ====================================================================
  # Function extraction — recognized-function keywords (ARE extracted)
  # ====================================================================

  def test_function_coalesce
    assert_includes analyze("SELECT coalesce(a, b) FROM t").functions, "coalesce"
  end

  def test_function_nullif
    assert_includes analyze("SELECT nullif(a, 0) FROM t").functions, "nullif"
  end

  def test_function_greatest
    assert_includes analyze("SELECT greatest(a, b, c) FROM t").functions, "greatest"
  end

  def test_function_least
    assert_includes analyze("SELECT least(a, b) FROM t").functions, "least"
  end

  def test_function_extract
    assert_includes analyze("SELECT extract(year from d) FROM t").functions, "extract"
  end

  def test_function_trim
    assert_includes analyze("SELECT trim(both ' ' from s) FROM t").functions, "trim"
  end

  def test_function_substring
    assert_includes analyze("SELECT substring(s from 1 for 3) FROM t").functions, "substring"
  end

  def test_function_position
    assert_includes analyze("SELECT position('x' in s) FROM t").functions, "position"
  end

  def test_function_grouping
    assert_includes analyze("SELECT grouping(a) FROM t GROUP BY a").functions, "grouping"
  end

  # ====================================================================
  # Function extraction — non-function keywords (NOT extracted)
  # ====================================================================

  def test_exists_not_a_function
    result = analyze("SELECT * FROM t WHERE EXISTS (SELECT 1)")
    refute_includes result.functions, "exists"
    refute_includes result.functions, "EXISTS"
  end

  def test_cast_not_a_function
    result = analyze("SELECT CAST(x AS int) FROM t")
    refute_includes result.functions, "cast"
    refute_includes result.functions, "CAST"
  end

  def test_in_not_a_function
    result = analyze("SELECT * FROM t WHERE x IN (1, 2, 3)")
    refute_includes result.functions, "in"
    refute_includes result.functions, "IN"
  end

  def test_case_not_a_function
    result = analyze("SELECT CASE WHEN x THEN y END FROM t")
    refute_includes result.functions, "case"
    refute_includes result.functions, "CASE"
  end

  def test_array_not_a_function
    result = analyze("SELECT ARRAY[1, 2, 3]")
    refute_includes result.functions, "array"
    refute_includes result.functions, "ARRAY"
  end

  def test_row_not_a_function
    result = analyze("SELECT ROW(1, 2)")
    refute_includes result.functions, "row"
    refute_includes result.functions, "ROW"
  end

  # ====================================================================
  # EXTRACT(... FROM ...) — FROM inside parens not table ref
  # ====================================================================

  def test_extract_from_not_table_ref
    result = analyze("SELECT extract(year FROM hire_date) FROM employees")
    assert_equal ["employees"], result.tables
    assert_includes result.functions, "extract"
  end

  # ====================================================================
  # Strings containing SQL keywords — not parsed
  # ====================================================================

  def test_string_with_sql_keywords
    result = analyze("SELECT * FROM users WHERE name = 'SELECT * FROM secrets'")
    assert_equal ["users"], result.tables
    refute_includes result.tables, "secrets"
  end

  def test_dollar_string_with_sql_keywords
    result = analyze("SELECT $$DROP TABLE users$$ FROM t")
    assert_equal ["t"], result.tables
    refute_includes result.tables, "users"
  end

  # ====================================================================
  # Dollar-quoted strings with semicolons
  # ====================================================================

  def test_dollar_string_with_semicolons_no_error
    result = analyze("SELECT $$hello; world$$ FROM t")
    assert_equal ["t"], result.tables
  end
end
