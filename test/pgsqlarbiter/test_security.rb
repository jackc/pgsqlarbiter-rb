# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

# Regression tests for ways a query has got past, or could get past, the
# arbiter. Every query here refers to something outside the whitelist; none may
# be allowed.
class TestSecurity < Minitest::Test
  DOTLESS_I = "ı"

  def analyze(sql)
    Pgsqlarbiter.analyze(sql, schema: EMPTY_SCHEMA)
  end

  def judge(sql, types: [:select])
    Pgsqlarbiter.judge(sql, schema: TEST_SCHEMA, allowed_tables: ["users"], allowed_statement_types: types)
  end

  def refute_allowed(sql, types: [:select])
    verdict = judge(sql, types: types)
    refute verdict.allowed?, "expected denial of: #{sql.inspect}"
    verdict
  rescue Pgsqlarbiter::Error
    # Refusing to analyze the query at all is also a denial.
    nil
  end

  # --- Lexer agreement with PostgreSQL ---

  def test_carriage_return_ends_a_line_comment
    assert_equal ["secrets"], analyze("SELECT secret --\rFROM secrets").tables
    assert_equal ["set_config"], analyze("SELECT 1 --\r, set_config('a.b','x',false)").functions
  end

  def test_carriage_return_comment_cannot_hide_a_second_statement
    assert_raises(Pgsqlarbiter::MultipleStatementsError) do
      analyze("SELECT 1 --\r; CREATE TABLE audit(x int); SELECT 'ddl ran'")
    end
  end

  def test_dollar_inside_identifier_does_not_start_a_dollar_quote
    assert_equal ["secrets"], analyze("SELECT 1 AS a$x$, secret FROM secrets AS b$x$").tables
    assert_equal ["set_config"], analyze("SELECT 1 AS a$x$, set_config('a.b','x',false) AS b$x$").functions
  end

  def test_operator_does_not_swallow_a_comment_start
    assert_equal ["secrets"], analyze("SELECT 1 +-- $x$\n 2, secret FROM secrets --$x$").tables
    assert_equal ["secrets"], analyze("SELECT 1 +/* ' */ 2, secret FROM secrets --'").tables
  end

  def test_multibyte_characters_in_dollar_quoted_string
    assert_equal ["secrets"], analyze("SELECT $$éé$$, secret FROM secrets --$$").tables
  end

  def test_unicode_case_folding_does_not_create_keywords
    sql = "SELECT un#{DOTLESS_I}on.name, secrets.secret FROM users un#{DOTLESS_I}on, secrets"
    assert_equal %w[secrets users], analyze(sql).tables
  end

  def test_unicode_escaped_identifiers_are_decoded
    assert_equal ["secrets"], analyze('SELECT * FROM U&"\\0073ecrets"').tables
    assert_equal ["secrets"], analyze(%q{SELECT * FROM U&"!0073ecrets" UESCAPE '!'}).tables
    assert_equal ["pg_sleep"], analyze('SELECT U&"pg\\005Fsleep"(1)').functions
  end

  def test_unicode_escape_cannot_smuggle_a_dot_into_a_name
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT * FROM U&"pg_catalog\\002Epg_authid"') }
  end

  def test_continued_escape_string_cannot_hide_sql
    assert_empty analyze("SELECT E'a'\n'b\\' , pg_sleep(1) , ', 1").functions
    assert_equal ["pg_sleep"], analyze("SELECT 'a'\n'b\\' , pg_sleep(1) , ''").functions
  end

  # --- CTE names ---

  def test_cte_does_not_shadow_the_table_inside_its_own_definition
    assert_equal ["secrets"], analyze("WITH secrets AS (SELECT * FROM secrets) SELECT * FROM secrets").tables
  end

  def test_cte_is_not_visible_outside_its_statement
    sql = "SELECT secret FROM secrets WHERE EXISTS (WITH secrets AS (SELECT 1) SELECT 1)"
    assert_equal ["secrets"], analyze(sql).tables

    sql = "SELECT * FROM (WITH secrets AS (SELECT 2 AS x) SELECT * FROM secrets) y, secrets z"
    assert_equal ["secrets"], analyze(sql).tables
  end

  def test_cte_is_not_visible_to_earlier_ctes
    assert_equal ["b"], analyze("WITH a AS (SELECT * FROM b), b AS (SELECT 1) SELECT * FROM a").tables
  end

  def test_cte_never_hides_a_function_in_from
    sql = "WITH set_config AS (SELECT 1) SELECT * FROM set_config('a.b','x',false)"
    assert_equal ["set_config"], analyze(sql).functions
  end

  def test_cte_never_hides_a_qualified_name
    assert_equal ["public.users"], analyze("WITH users AS (SELECT 1) SELECT * FROM public.users").tables
  end

  def test_cte_never_hides_a_modification_target
    assert_equal ["secrets"], analyze("WITH secrets AS (SELECT 1) DELETE FROM secrets").tables
    assert_equal ["secrets"], analyze("WITH secrets AS (SELECT 1) UPDATE secrets SET id = 1").tables
    assert_equal ["secrets"], analyze("WITH secrets AS (SELECT 1) INSERT INTO secrets VALUES (1)").tables
  end

  def test_cte_names_are_case_folded_like_other_identifiers
    assert_equal ["users"], analyze('WITH "Users" AS (SELECT 1) SELECT * FROM users').tables
    assert_empty analyze("WITH Users AS (SELECT 1) SELECT * FROM USERS").tables
  end

  def test_with_ordinality_and_with_ties_do_not_create_cte_names
    sql = "SELECT * FROM unnest(ARRAY[1]) WITH ORDINALITY, ordinality"
    assert_equal ["ordinality"], analyze(sql).tables
    sql = "SELECT * FROM ties ORDER BY 1 FETCH FIRST 1 ROWS WITH TIES"
    assert_equal ["ties"], analyze(sql).tables
  end

  # --- Table references ---

  def test_table_command
    assert_equal ["secrets"], analyze("SELECT * FROM (TABLE secrets) x").tables
    assert_equal %w[secrets users], analyze("SELECT id, name FROM users UNION ALL TABLE secrets").tables
    assert_equal ["secrets"], analyze("TABLE secrets").tables
    assert_equal ["secrets"], analyze("SELECT ARRAY(TABLE secrets)").tables
  end

  def test_subquery_inside_functions_with_from_syntax
    assert_equal ["secrets"], analyze("SELECT trim((SELECT secret FROM secrets LIMIT 1))").tables
    assert_equal ["secrets"], analyze("SELECT substring((SELECT secret FROM secrets) FROM 1)").tables
    assert_equal ["secrets"], analyze("SELECT extract(epoch FROM (SELECT ts FROM secrets))").tables
    assert_equal ["secrets"], analyze("SELECT overlay('a' PLACING (SELECT s FROM secrets) FROM 1)").tables
  end

  def test_every_item_of_a_from_list_is_seen
    assert_equal %w[secrets users], analyze("SELECT 1 FROM users u JOIN users u2 ON true, secrets s").tables
    assert_equal %w[secrets users], analyze("SELECT 1 FROM users *, secrets s").tables
    assert_equal ["secrets"], analyze("SELECT 1 FROM unnest(ARRAY[1]) WITH ORDINALITY, secrets s").tables
    assert_equal %w[secrets users], analyze("SELECT 1 FROM users TABLESAMPLE bernoulli (1), secrets").tables
    assert_equal %w[secrets users], analyze("SELECT 1 FROM users JOIN users u2 USING (id), secrets").tables
  end

  def test_parenthesized_relations
    assert_equal %w[secrets users], analyze("SELECT * FROM (secrets CROSS JOIN users)").tables
    assert_equal ["secrets"], analyze("SELECT * FROM ONLY (secrets)").tables
    assert_equal %w[orders secrets users],
      analyze("SELECT * FROM users u LEFT JOIN (secrets s JOIN orders o USING (id)) ON true").tables
  end

  def test_using_list_in_delete
    sql = "DELETE FROM users USING users u2, secrets s WHERE false RETURNING s.secret"
    assert_equal %w[secrets users], analyze(sql).tables
  end

  def test_subqueries_everywhere
    [
      "SELECT 1 ORDER BY (SELECT id FROM secrets LIMIT 1)",
      "SELECT 1 LIMIT (SELECT id FROM secrets LIMIT 1)",
      "SELECT 1 OFFSET (SELECT id FROM secrets LIMIT 1)",
      "SELECT 1 FETCH FIRST (SELECT id FROM secrets LIMIT 1) ROWS ONLY",
      "SELECT count(*) FILTER (WHERE id IN (SELECT id FROM secrets)) FROM users",
      "SELECT sum(id) OVER (PARTITION BY (SELECT id FROM secrets LIMIT 1)) FROM users",
      "SELECT 1 FROM users GROUP BY (SELECT id FROM secrets LIMIT 1)",
      "SELECT 1 FROM users HAVING EXISTS (TABLE secrets)",
      "SELECT CASE WHEN true THEN (SELECT secret FROM secrets LIMIT 1) END",
      "SELECT (ARRAY[1])[(SELECT id FROM secrets LIMIT 1)]",
      "SELECT 1 FROM users WHERE name IS DISTINCT FROM (SELECT secret FROM secrets LIMIT 1)",
      "VALUES ((SELECT secret FROM secrets LIMIT 1))",
      "SELECT JSON_ARRAY(SELECT id FROM secrets)",
      "SELECT x::numeric((SELECT id FROM secrets)) FROM users"
    ].each do |sql|
      assert_includes analyze(sql).tables, "secrets", sql
    end
  end

  def test_insert_column_list_with_alias_is_analyzed
    sql = "INSERT INTO users AS u (id, data[(SELECT secret FROM secrets)]) VALUES (9, '1')"
    assert_equal %w[secrets users], analyze(sql).tables
  end

  # --- Statement types ---

  def test_data_modifying_cte_needs_its_own_statement_type
    sql = "WITH d AS (DELETE FROM users WHERE id = 2 RETURNING *) SELECT * FROM d"
    analysis = analyze(sql)
    assert_equal :select, analysis.statement_type
    assert_equal [:delete, :select], analysis.statement_types

    verdict = refute_allowed(sql)
    assert_equal [:delete], verdict.disallowed_statement_types
    assert judge(sql, types: [:select, :delete]).allowed?
  end

  def test_nested_data_modifying_ctes
    sql = "WITH a AS (WITH b AS (INSERT INTO users VALUES (1) RETURNING *) UPDATE users SET id = 2 RETURNING *) SELECT * FROM a"
    assert_equal [:insert, :select, :update], analyze(sql).statement_types
  end

  def test_cte_named_like_a_statement_keyword
    sql = "WITH insert AS (SELECT 1) DELETE FROM users WHERE false"
    assert_equal :delete, analyze(sql).statement_type
    refute_allowed(sql, types: [:insert])

    sql = "WITH values AS (SELECT 1) DELETE FROM users WHERE false"
    assert_equal :delete, analyze(sql).statement_type
  end

  def test_row_locks_need_update
    ["FOR UPDATE", "FOR NO KEY UPDATE", "FOR SHARE", "FOR KEY SHARE", "FOR UPDATE OF users NOWAIT"].each do |lock|
      sql = "SELECT * FROM users #{lock}"
      assert_equal [:select, :update], analyze(sql).statement_types, sql
      refute_allowed(sql)
      assert judge(sql, types: [:select, :update]).allowed?, sql
    end
    assert_equal [:select], analyze("SELECT * FROM users FOR READ ONLY").statement_types
  end

  def test_on_conflict_do_update_needs_update
    sql = "INSERT INTO users (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET id = 2"
    assert_equal [:insert, :update], analyze(sql).statement_types
    refute_allowed(sql, types: [:insert])
    assert_equal [:insert], analyze("INSERT INTO users (id) VALUES (1) ON CONFLICT DO NOTHING").statement_types
  end

  def test_select_into_is_refused
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SELECT * INTO newtab FROM users") }
    assert_raises(Pgsqlarbiter::DisallowedStatementError) { analyze("SELECT * INTO TEMP newtab FROM users") }
    assert_raises(Pgsqlarbiter::DisallowedStatementError) do
      analyze("WITH temp AS (SELECT 1) SELECT * INTO temp made_by_select FROM users")
    end
  end

  def test_where_current_of_is_refused
    assert_raises(Pgsqlarbiter::ParseError) { analyze("DELETE FROM users WHERE CURRENT OF c") }
  end

  # --- Functions ---

  def test_ts_rewrite_is_not_allowed_by_default
    refute_includes Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS, "ts_rewrite"
    refute_allowed("SELECT ts_rewrite('a'::tsquery, 'select 1')")
  end

  def test_functions_without_parentheses_are_functions
    sql = "SELECT current_user, session_user, current_catalog, current_schema, user, current_role, system_user"
    assert_equal %w[current_catalog current_role current_schema current_user session_user system_user user],
      analyze(sql).functions
    refute_allowed(sql)
    assert judge("SELECT current_date, current_timestamp, localtime").allowed?
  end

  def test_functions_named_like_keywords
    assert_equal %w[date text], analyze("SELECT text(1), date('2020-01-01')").functions
    assert_equal %w[filter first last], analyze("SELECT first(1), last(2), filter(3)").functions
    assert_equal ["left"], analyze("SELECT left('abc', 1)").functions
  end

  def test_function_name_variants
    ["pg_sleep(1)", '"pg_sleep"(1)', "PG_SLEEP (1)", "pg_sleep /* c */ (1)", "pg_sleep\n(1)"].each do |call|
      assert_equal ["pg_sleep"], analyze("SELECT #{call}").functions, call
    end
    assert_equal ["pg_catalog.pg_sleep"], analyze("SELECT pg_catalog.pg_sleep(1)").functions
    assert_equal ["db.pg_catalog.pg_sleep"], analyze("SELECT db.pg_catalog.pg_sleep(1)").functions
  end

  def test_functions_in_every_clause
    [
      "SELECT 1 WHERE pg_sleep(1) IS NULL",
      "SELECT 1 FROM users ORDER BY pg_sleep(1)",
      "SELECT 1 FROM users GROUP BY ROLLUP (pg_sleep(1))",
      "SELECT sum(1) OVER (ORDER BY pg_sleep(1) ROWS BETWEEN pg_sleep(1) PRECEDING AND CURRENT ROW) FROM users",
      "SELECT sum(1) OVER w FROM users WINDOW w AS (PARTITION BY pg_sleep(1))",
      "SELECT array_agg(1 ORDER BY pg_sleep(1))",
      "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY pg_sleep(1))",
      "SELECT DISTINCT ON (pg_sleep(1)) 1",
      "SELECT * FROM ROWS FROM (pg_sleep(1), generate_series(1, 2)) x",
      "SELECT * FROM users, LATERAL pg_sleep(1)",
      "SELECT * FROM users TABLESAMPLE system (pg_sleep(1))",
      "SELECT * FROM JSON_TABLE('[]', '$' COLUMNS (a int PATH '$' DEFAULT pg_sleep(1) ON EMPTY)) j",
      "SELECT 'a' LIKE 'b' ESCAPE pg_sleep(1)::text",
      "SELECT now() AT TIME ZONE pg_sleep(1)::text",
      "SELECT ROW(pg_sleep(1)), ARRAY[pg_sleep(1)]",
      "SELECT 1::numeric(pg_sleep(1))",
      "INSERT INTO users (id) VALUES (1) ON CONFLICT (pg_sleep(1)) DO NOTHING",
      "INSERT INTO users VALUES (1) RETURNING pg_sleep(1)",
      "UPDATE users SET id = pg_sleep(1)",
      "MERGE INTO users u USING users s ON pg_sleep(1) IS NULL WHEN MATCHED THEN DO NOTHING"
    ].each do |sql|
      assert_includes analyze(sql).functions, "pg_sleep", sql
    end
  end

  def test_tablesample_method_is_a_function
    assert_includes analyze("SELECT * FROM users TABLESAMPLE bernoulli (10)").functions, "bernoulli"
  end

  def test_qualified_operator_syntax_is_refused
    assert_raises(Pgsqlarbiter::ParseError) { analyze("SELECT 1 OPERATOR(pg_catalog.+) 2") }
    assert_raises(Pgsqlarbiter::ParseError) { analyze("SELECT * FROM users ORDER BY id USING OPERATOR(pg_catalog.<)") }
    assert_raises(Pgsqlarbiter::ParseError) { analyze("SELECT 1 = ANY (ARRAY[1]) , 1 OPERATOR(pg_catalog.=) ANY (ARRAY[1])") }
  end

  # --- Attribute notation: x.f is the call f(x) when x has no column f ---

  def test_attribute_of_an_expression_is_a_possible_function_call
    assert_equal ["pg_sleep"], analyze("SELECT (10).pg_sleep").functions
    assert_equal ["current_setting"], analyze("SELECT ('server_version'::text).current_setting").functions
    assert_equal ["pg_sleep"], analyze("SELECT (SELECT 10).pg_sleep").functions
    assert_equal ["pg_sleep"], analyze("SELECT ($1).pg_sleep").functions
    assert_equal ["pg_sleep"], analyze("SELECT (id).pg_sleep FROM users").functions
    assert_equal ["pg_sleep"], analyze("SELECT (u.id).pg_sleep FROM users u").functions
    refute_allowed("SELECT (10).pg_sleep")
  end

  def test_attribute_after_a_subscript_is_a_possible_function_call
    assert_equal ["pg_read_file"], analyze("SELECT tags[1].pg_read_file FROM users").functions
    assert_equal ["pg_read_file"], analyze("SELECT u.tags[1].pg_read_file FROM users u").functions
    assert_equal ["pg_sleep"], analyze("SELECT (ARRAY[1])[1].pg_sleep").functions
  end

  def test_attribute_of_a_function_in_from_is_a_possible_function_call
    assert_equal %w[generate_series pg_sleep], analyze("SELECT g.pg_sleep FROM generate_series(1, 3) g").functions
    assert_equal %w[generate_series pg_sleep], analyze("SELECT generate_series.pg_sleep FROM generate_series(1, 3)").functions
    assert_equal %w[current_setting unnest],
      analyze("SELECT s.current_setting FROM unnest(ARRAY['server_version']) s").functions
    assert_equal %w[generate_series pg_sleep],
      analyze("SELECT (SELECT g.pg_sleep) FROM generate_series(1, 3) g").functions
    assert_equal %w[generate_series pg_sleep],
      analyze("SELECT 1 FROM generate_series(1, 3) g ORDER BY g.pg_sleep").functions
    assert_equal %w[generate_series pg_sleep],
      analyze("SELECT s.pg_sleep FROM ROWS FROM (generate_series(1, 3)) s").functions
    refute_allowed("SELECT g.pg_sleep FROM generate_series(1, 3) g")
  end

  def test_declared_columns_of_a_function_in_from_are_columns
    assert_equal ["generate_series"], analyze("SELECT g.n FROM generate_series(1, 3) AS g(n)").functions
    assert_equal ["generate_series"], analyze("SELECT g.g FROM generate_series(1, 3) g").functions
    assert_equal ["json_to_record"], analyze("SELECT j.a FROM json_to_record('{}') AS j(a int)").functions
    assert_equal %w[generate_series pg_sleep],
      analyze("SELECT g.n, g.pg_sleep FROM generate_series(1, 3) AS g(n)").functions
  end

  def test_known_columns_of_built_in_functions_in_from
    assert_equal ["jsonb_each"], analyze("SELECT e.key, e.value FROM jsonb_each($1) e").functions
    assert_equal ["pg_catalog.json_each_text"], analyze("SELECT e.key FROM pg_catalog.json_each_text($1) e").functions
    assert_equal %w[jsonb_each pg_sleep], analyze("SELECT e.pg_sleep FROM jsonb_each($1) e").functions
    assert_equal %w[key other.jsonb_each], analyze("SELECT e.key FROM other.jsonb_each($1) e").functions
    assert_equal ["unnest"], analyze("SELECT t.ordinality FROM unnest($1) WITH ORDINALITY t").functions
    assert_equal %w[ordinality unnest], analyze("SELECT t.ordinality FROM unnest($1) t").functions
  end

  def test_same_alias_in_two_scopes_uses_the_stricter_reading
    sql = "SELECT (SELECT g.n FROM generate_series(1, 2) AS g(n)), g.n FROM generate_series(1, 2) g"
    assert_equal %w[generate_series n], analyze(sql).functions
  end

  def test_function_in_from_without_a_certain_name_makes_every_qualified_column_suspect
    sql = "SELECT d.pg_sleep, u.name FROM users u, current_date"
    assert_equal %w[current_date name pg_sleep], analyze(sql).functions
  end

  def test_columns_of_tables_are_not_treated_as_functions
    assert_empty analyze("SELECT u.name, users.id FROM users u, users").functions
    assert_empty analyze("SELECT x.a FROM (SELECT 1 AS a) x").functions
    assert_empty analyze("SELECT public.users.name FROM public.users").functions
  end

  # --- Types ---

  def test_object_identifier_casts_are_not_allowed_by_default
    ["'secrets'::regclass", "CAST('pg_sleep' AS regproc)", "regclass 'secrets'", "'x'::regtype",
      "'x'::pg_catalog.regclass", "ARRAY['x']::regclass[]"].each do |expr|
      refute_allowed("SELECT #{expr}")
    end
    assert_equal ["regclass"], analyze("SELECT 'secrets'::regclass::oid > 0").types - ["oid"]
  end

  def test_casting_to_a_table_row_type_is_recorded
    assert_equal ["secrets"], analyze("SELECT (NULL::secrets).*").types
    refute_allowed("SELECT (NULL::secrets).*")
    assert_equal ["secrets"], analyze("SELECT * FROM json_populate_record(NULL::secrets, '{}')").types
  end

  def test_types_in_every_position
    {
      "SELECT x::secret_t FROM users" => "secret_t",
      "SELECT CAST(x AS secret_t) FROM users" => "secret_t",
      "SELECT secret_t 'x'" => "secret_t",
      "SELECT secret_t(3) 'x'" => "secret_t",
      "SELECT * FROM json_to_record('{}') AS x(a secret_t)" => "secret_t",
      "SELECT * FROM ROWS FROM (json_to_record('{}') AS (a secret_t)) x" => "secret_t",
      "SELECT * FROM XMLTABLE('/r' PASSING $1 COLUMNS a secret_t PATH '.') t" => "secret_t",
      "SELECT * FROM JSON_TABLE($1, '$' COLUMNS (a secret_t PATH '$')) t" => "secret_t",
      "SELECT JSON_VALUE(x, '$' RETURNING secret_t) FROM users" => "secret_t",
      "SELECT XMLSERIALIZE(CONTENT x AS secret_t) FROM users" => "secret_t",
      "SELECT x::s.secret_t[] FROM users" => "s.secret_t",
      "SELECT TREAT(x AS secret_t) FROM users" => "secret_t"
    }.each do |sql, type|
      assert_includes analyze(sql).types, type, sql
    end
  end

  # --- The analyzer cannot be made to work hard ---

  def test_many_semicolons
    Timeout.timeout(5) { assert_equal :select, analyze("SELECT 1" + ";" * 200_000).statement_type }
  end

  def test_many_statements
    Timeout.timeout(5) do
      assert_raises(Pgsqlarbiter::MultipleStatementsError) { analyze("SELECT 1;" * 50_000) }
    end
  end

  def test_many_dollar_quoted_strings
    Timeout.timeout(5) { analyze("SELECT " + (["$$x$$"] * 20_000).join(", ")) }
  end

  def test_deep_nesting_does_not_overflow_the_stack
    depth = 20_000
    Timeout.timeout(20) do
      assert_equal ["secrets"], analyze("SELECT #{"(" * depth}(SELECT id FROM secrets)#{")" * depth}").tables
      assert_equal ["secrets"], analyze("#{"(" * depth}TABLE secrets#{")" * depth}").tables
      assert_equal ["secrets"],
        analyze("SELECT * FROM #{"(SELECT * FROM " * 2_000}secrets#{") x" * 2_000}").tables
    end
  end

  def test_long_lists_do_not_overflow_the_stack
    Timeout.timeout(20) do
      columns = (1..20_000).map { |n| "c#{n} + #{n}" }.join(", ")
      assert_equal ["secrets"], analyze("SELECT #{columns} FROM secrets").tables
      name = (["a"] * 20_000).join(".")
      assert_equal [name], analyze("SELECT * FROM #{name}").tables
      assert_equal ["secrets"], analyze("SELECT 1 FROM secrets WHERE #{(["x = 1"] * 20_000).join(" AND ")}").tables
    end
  end

  def test_unterminated_constructs_at_scale
    Timeout.timeout(5) do
      assert_raises(Pgsqlarbiter::LexError) { analyze("SELECT " + "/*" * 100_000) }
      assert_raises(Pgsqlarbiter::LexError) { analyze("SELECT '" + "''" * 100_000) }
      assert_empty analyze("SELECT 'a'" + "\n--x" * 100_000).tables
    end
  end

  # --- Errors are always Pgsqlarbiter::Error ---

  def test_bad_input_raises_only_pgsqlarbiter_errors
    ["SELECT '\xff'", "SELECT 1\0", "SELECT ,", "SELECT FROM WHERE", "(", ")", "SELECT 1 +", "WITH", " ",
      "SELECT * FROM t t2 t3", "SELECT 1 2", ";", ";;;", "SELECT $", "x", "1", "'a'"].each do |sql|
      assert_raises(Pgsqlarbiter::Error, sql.inspect) { analyze(sql) }
    end
    assert_raises(Pgsqlarbiter::Error) { analyze(nil) }
  end
end
