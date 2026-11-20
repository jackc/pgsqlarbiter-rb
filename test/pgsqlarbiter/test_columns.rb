# frozen_string_literal: true

require_relative "../test_helper"

# Name resolution against a schema: telling a column from a function call
# written in attribute notation, and finding every column a query uses.
class TestColumns < Minitest::Test
  SCHEMA = Pgsqlarbiter::Schema.new(
    {
      "users" => %w[id name email password_hash tags],
      "orders" => %w[id user_id total],
      "public.users" => %w[id name email password_hash tags],
      "notes" => %w[id old new body]
    },
    functions: BUILTIN_FUNCTIONS.merge("report" => %w[month total], "active_ids" => :scalar, "lower" => :unknown)
  )

  def analyze(sql)
    Pgsqlarbiter.analyze(sql, schema: SCHEMA)
  end

  def functions(sql) = analyze(sql).functions

  def columns(sql) = analyze(sql).columns

  def assert_unresolved(sql)
    assert_raises(Pgsqlarbiter::UnresolvedNameError, sql) { analyze(sql) }
  end

  # --- Attribute notation on a whole row ---

  def test_column_of_a_table_is_not_a_function
    assert_empty functions("SELECT u.name FROM users u")
    assert_empty functions("SELECT users.name FROM users")
    assert_empty functions("SELECT public.users.name FROM public.users")
    assert_empty functions("SELECT u.ctid, u.xmin, u.tableoid FROM users u")
  end

  def test_unknown_attribute_of_a_table_is_a_function_call_on_the_whole_row
    result = analyze("SELECT u.secret_stuff FROM users u")
    assert_equal ["secret_stuff"], result.functions
    assert_equal ["users.*"], result.columns
    assert_equal ["secret_stuff"], functions("SELECT users.secret_stuff FROM users")
    assert_equal ["secret_stuff"], functions("SELECT public.users.secret_stuff FROM public.users")
    assert_equal ["secret_stuff"], functions("SELECT 1 FROM users u WHERE u.secret_stuff > 0")
    assert_equal ["secret_stuff"], functions("SELECT 1 FROM users u ORDER BY u.secret_stuff")
    assert_equal ["secret_stuff"], functions("UPDATE users u SET name = u.secret_stuff")
    assert_equal ["secret_stuff"], functions("DELETE FROM users u WHERE u.secret_stuff")
  end

  def test_type_name_as_attribute_is_a_cast_of_the_row
    assert_equal ["text"], functions("SELECT u.text FROM users u")
  end

  def test_column_names_are_per_table
    assert_equal ["total"], functions("SELECT u.total FROM users u, orders o")
    assert_empty functions("SELECT o.total FROM users u, orders o")
  end

  def test_subquery_columns
    assert_empty functions("SELECT x.id FROM (SELECT id FROM users) x")
    assert_empty functions("SELECT x.uid FROM (SELECT id AS uid FROM users) x")
    assert_empty functions("SELECT x.uid FROM (SELECT id uid FROM users) x")
    assert_empty functions("SELECT x.name FROM (SELECT * FROM users) x")
    assert_empty functions("SELECT x.name FROM (SELECT u.* FROM users u) x")
    assert_equal ["id"], functions("SELECT x.id FROM (SELECT id AS uid FROM users) x")
    assert_equal ["name"], functions("SELECT x.name FROM (SELECT id FROM users) x")
    assert_equal ["secret_stuff"], functions("SELECT x.secret_stuff FROM (SELECT * FROM users) x")
    assert_equal ["total"], functions("SELECT x.total FROM (SELECT u.* FROM users u, orders o) x")
  end

  def test_names_of_unlabelled_result_columns
    assert_empty functions("SELECT x.name FROM (SELECT u.name FROM users u) x")
    assert_empty functions("SELECT x.name FROM (SELECT (name) FROM users) x")
    assert_empty functions("SELECT x.name FROM (SELECT name::text FROM users) x")
    assert_empty functions("SELECT x.tags FROM (SELECT tags[1] FROM users) x")
    assert_equal ["count"], functions("SELECT x.count FROM (SELECT count(*) FROM users) x")
    assert_equal ["max"], functions("SELECT x.max FROM (SELECT max(id) FILTER (WHERE id > 0) FROM users) x")
    assert_equal %w[coalesce name], functions("SELECT x.name FROM (SELECT coalesce(name) FROM users) x")
    assert_equal ["name"], functions("SELECT x.name FROM (SELECT name || 'x' FROM users) x")
    assert_equal ["name"], functions("SELECT x.name FROM (SELECT - id FROM users) x")
  end

  def test_values_columns
    assert_empty functions("SELECT v.column1, v.column2 FROM (VALUES (1, 2), (3, 4)) v")
    assert_equal ["column3"], functions("SELECT v.column3 FROM (VALUES (1, 2)) v")
    assert_empty functions("SELECT v.a, v.b FROM (VALUES (1, 2)) AS v(a, b)")
    assert_equal ["column1"], functions("SELECT v.column1 FROM (VALUES (1, 2)) AS v(a, b)")
  end

  def test_set_operation_takes_its_names_from_the_left
    sql = "SELECT x.%s FROM (SELECT id FROM users UNION ALL SELECT user_id FROM orders) x"
    assert_empty functions(format(sql, "id"))
    assert_equal ["user_id"], functions(format(sql, "user_id"))
  end

  def test_column_alias_list_renames_columns
    assert_equal ["id"], functions("SELECT x.id FROM (SELECT id FROM users) AS x(uid)")
    assert_empty functions("SELECT x.uid FROM (SELECT id FROM users) AS x(uid)")
    assert_equal ["id"], functions("SELECT u.id FROM users AS u(uid)")
    assert_empty functions("SELECT u.uid FROM users AS u(uid)")
  end

  def test_table_with_a_column_alias_list_counts_as_read_in_full
    assert_equal ["users.*"], columns("SELECT u.uid FROM users AS u(uid)")
  end

  def test_cte_columns
    assert_empty functions("WITH c AS (SELECT id FROM users) SELECT c.id FROM c")
    assert_equal ["name"], functions("WITH c AS (SELECT id FROM users) SELECT c.name FROM c")
    assert_empty functions("WITH c(uid) AS (SELECT id FROM users) SELECT c.uid FROM c")
    assert_equal ["id"], functions("WITH c(uid) AS (SELECT id FROM users) SELECT c.id FROM c")
    assert_empty functions("WITH c AS (SELECT id FROM users) SELECT d.id FROM c d")
    assert_empty functions("WITH RECURSIVE c AS (SELECT 1 AS n UNION ALL SELECT c.n + 1 FROM c WHERE n < 3) SELECT c.n FROM c")
    assert_empty functions("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) SELECT n FROM c")
    assert_empty functions("WITH c AS (DELETE FROM orders RETURNING id, total) SELECT c.id, c.total FROM c")
    assert_equal ["user_id"], functions("WITH c AS (DELETE FROM orders RETURNING id) SELECT c.user_id FROM c")
    assert_empty functions("WITH c AS (DELETE FROM orders RETURNING *) SELECT c.user_id FROM c")
  end

  def test_cte_named_like_a_table_has_the_cte_columns
    assert_equal ["name"], functions("WITH users AS (SELECT 1 AS x) SELECT users.name FROM users")
    assert_empty functions("WITH users AS (SELECT 1 AS x) SELECT users.x FROM users")
  end

  def test_join_alias
    assert_empty functions("SELECT j.name, j.total FROM (users u JOIN orders o ON true) AS j")
    assert_equal ["secret_stuff"], functions("SELECT j.secret_stuff FROM (users u JOIN orders o ON true) AS j")
    assert_equal ["name"], functions("SELECT j.name FROM (users u JOIN orders o ON true) AS j(a, b)")
    assert_empty functions("SELECT j.a FROM (users u JOIN orders o ON true) AS j(a, b)")
    assert_equal ["name"], functions("SELECT x.name FROM (SELECT * FROM (users u JOIN orders o ON true) AS j(a)) x")
  end

  def test_join_alias_charges_the_tables_underneath
    assert_equal %w[orders.total users.name], columns("SELECT j.name, j.total FROM (users u JOIN orders o ON true) AS j")
    assert_equal %w[orders.* users.*], columns("SELECT j.a FROM (users u JOIN orders o ON true) AS j(a)")
    assert_equal %w[orders.* users.*], columns("SELECT j FROM (users u JOIN orders o ON true) AS j")
  end

  def test_join_using_alias
    assert_empty functions("SELECT j.id, u.name FROM users u JOIN orders o USING (id) AS j")
    assert_equal ["name"], functions("SELECT j.name FROM users u JOIN orders o USING (id) AS j")
  end

  def test_using_and_natural_read_columns
    assert_equal %w[orders.id users.id], columns("SELECT 1 FROM users JOIN orders USING (id)")
    assert_equal %w[orders.* users.*], columns("SELECT 1 FROM users NATURAL JOIN orders")
  end

  def test_outer_alias_in_a_subquery
    assert_empty functions("SELECT (SELECT u.name) FROM users u")
    assert_equal ["secret_stuff"], functions("SELECT (SELECT u.secret_stuff) FROM users u")
    assert_equal ["secret_stuff"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.id = u.secret_stuff)")
    assert_equal ["secret_stuff"], functions("SELECT 1 FROM users u, LATERAL (SELECT u.secret_stuff) x")
  end

  def test_same_alias_at_two_levels_means_the_nearest
    assert_empty functions("SELECT (SELECT u.total FROM orders u LIMIT 1) FROM users u")
    assert_equal ["orders.total"], columns("SELECT (SELECT u.total FROM orders u LIMIT 1) FROM users u")
    assert_equal ["name"], functions("SELECT (SELECT u.name FROM orders u LIMIT 1) FROM users u")
    assert_equal ["orders.*"], columns("SELECT (SELECT u.name FROM orders u LIMIT 1) FROM users u")
    assert_empty functions("SELECT u.name FROM users u WHERE EXISTS (SELECT 1 FROM orders u WHERE u.total > 0)")
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE EXISTS (SELECT 1 FROM orders u WHERE u.total = o.total))")
    assert_equal ["orders.*"], columns("SELECT (SELECT u.* FROM orders u LIMIT 1) FROM users u")
  end

  def test_nearest_alias_must_be_visible_where_it_is_used
    # A non-LATERAL subquery in FROM cannot see the other items of its FROM,
    # so PostgreSQL looks for u further out.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u, (SELECT u.total) x)")
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u, LATERAL (SELECT u.total) x)")
    # A join's ON clause cannot see FROM items written after it.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders o JOIN orders p ON u.total = 1, orders u)")
    # Tables inside a join with an alias cannot be named from outside it.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM (orders u JOIN orders p ON true) j WHERE u.total = 1)")
    # A schema-qualified name matches only some of the FROM items of its name.
    assert_equal ["total"],
      functions("SELECT 1 FROM public.users WHERE EXISTS (SELECT 1 FROM users WHERE public.users.total = 1)")
  end

  def test_on_clause_sees_the_members_of_its_join
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p ON p.id = u.total)")
    assert_equal ["orders.id", "orders.total"],
      columns("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p ON p.id = u.total)")
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders p JOIN orders u ON p.id = u.total)")
    assert_empty functions("SELECT 1 FROM users u LEFT JOIN LATERAL (SELECT 1 FROM orders u JOIN orders p ON p.id = u.total) x ON true")
    # Both sides of an outer join, including the members of an inner join
    # without an alias.
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders o JOIN (orders u JOIN orders p ON true) ON o.id = u.total)")
    # Inside a join with an alias, its members are still visible.
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM (orders u JOIN orders p ON p.id = u.total) j)")
    # A subquery in ON sees the same.
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p ON EXISTS (SELECT 1 WHERE u.total = 1))")
    assert_equal ["generate_series"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p ON p.id IN (SELECT 1 FROM generate_series(1, u.total)))")
  end

  def test_on_clause_does_not_see_beyond_its_join
    # FROM items outside the join, before or after it.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u, orders o JOIN orders p ON u.total = 1)")
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders o JOIN orders p ON u.total = 1 JOIN orders u ON true)")
    # Tables hidden by an inner join's alias.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM (orders u JOIN orders p ON true) j JOIN orders q ON u.total = 1)")
    # A subquery in FROM, even inside a join, is not part of its ON clause.
    assert_equal ["total"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN LATERAL (SELECT u.total) x ON true)")
  end

  def test_on_clause_ignores_what_it_cannot_see_at_its_level
    # A table of the same name hidden by an inner join's alias.
    sql = "SELECT 1 FROM (orders u JOIN orders p ON true) j JOIN users u ON u.name = 'a'"
    assert_empty functions(sql)
    assert_equal ["users.name"], columns(sql)
    # A join alias that reuses the name of a member it hides.
    sql = "SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM (orders u JOIN users p ON true) u JOIN orders q ON u.total = u.name)"
    assert_empty functions(sql)
    assert_equal ["orders.total", "users.name"], columns(sql)
    # Inside that join, the name still means the member.
    assert_equal ["name"],
      functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM (orders u JOIN users p ON u.name = 'a') u)")
  end

  def test_on_clause_sees_members_under_a_using_alias
    # USING (...) AS j names the join without hiding its members.
    sql = "SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p USING (id) AS j JOIN orders q ON u.total = j.id)"
    assert_empty functions(sql)
    assert_equal ["orders.id", "orders.total"], columns(sql)
  end

  def test_on_clause_of_a_chain_sees_every_join_before_it
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN orders p ON true JOIN orders q ON u.total = 1)")
    # After an inner ON condition ends, the outer one sees its own join again.
    assert_empty functions("SELECT 1 FROM users u WHERE EXISTS (SELECT 1 FROM orders u JOIN (orders p JOIN orders q ON p.id = q.id) ON u.total = p.id)")
  end

  def test_on_clause_in_data_modifying_statements
    assert_empty functions("UPDATE orders SET total = 1 FROM orders u JOIN orders p ON u.total = p.id")
    assert_equal ["orders.id", "orders.total"],
      columns("UPDATE orders SET total = 1 FROM orders u JOIN orders p ON u.total = p.id")
    assert_empty functions("DELETE FROM users USING orders u JOIN orders p ON u.total = p.id")
    assert_empty functions("MERGE INTO orders t USING (orders u JOIN orders p ON u.total = 1) ON t.id = u.id WHEN MATCHED THEN DELETE")
    assert_empty functions("MERGE INTO orders t USING orders u JOIN orders p ON u.total = 1 ON t.id = u.id WHEN MATCHED THEN DELETE")
  end

  def test_long_join_chain_stays_within_the_work_limit
    joins = (1..4000).map { |i| " JOIN orders t#{i} ON t#{i}.id = t#{i - 1}.id" }.join
    assert_equal ["orders.id"], columns("SELECT 1 FROM orders t0#{joins}")
  end

  def test_cte_cannot_see_the_from_items_of_its_statement
    assert_empty functions("WITH x AS (SELECT u.total FROM orders u) SELECT u.name FROM users u, x")
    assert_equal ["orders.total", "users.name"],
      columns("WITH x AS (SELECT u.total FROM orders u) SELECT u.name FROM users u, x")
    assert_unresolved("WITH x AS (SELECT o.id FROM orders) SELECT 1 FROM users o, x")
    assert_unresolved("WITH x AS (SELECT email FROM orders) SELECT 1 FROM users, x")
    assert_unresolved("WITH x AS (SELECT 1 FROM orders WHERE o.id = 1) UPDATE orders o SET total = 1 FROM x")
  end

  def test_cte_inside_a_subquery_sees_the_levels_around_it
    assert_empty functions("SELECT (WITH x AS (SELECT u.name) SELECT x.name FROM x) FROM users u")
    assert_equal ["users.name"], columns("SELECT (WITH x AS (SELECT u.name) SELECT x.name FROM x) FROM users u")
    assert_equal ["total"],
      functions("SELECT (WITH x AS (SELECT u.total) SELECT 1 FROM x, orders u) FROM users u")
  end

  def test_unknown_qualifier_is_refused
    assert_unresolved("SELECT z.id FROM users u")
    assert_unresolved("SELECT users.id FROM users u, (SELECT 1) z WHERE zz.id = 1")
    assert_unresolved("SELECT z.* FROM users u")
  end

  # --- Functions in FROM ---

  def test_declared_function_columns
    assert_equal ["report"], functions("SELECT r.month, r.total FROM report() r")
    assert_equal %w[pg_sleep report], functions("SELECT r.pg_sleep FROM report() r")
    assert_equal ["report"], functions("SELECT report.month FROM report()")
    assert_equal ["report"], functions("SELECT r.month, r.ordinality FROM report() WITH ORDINALITY r")
    assert_equal %w[ordinality report], functions("SELECT r.ordinality FROM report() r")
    assert_equal ["report"], functions("SELECT month, total FROM report()")
  end

  def test_declared_scalar_function
    assert_equal ["active_ids"], functions("SELECT a.a FROM active_ids() a")
    assert_equal ["active_ids"], functions("SELECT active_ids.active_ids FROM active_ids()")
    assert_equal %w[active_ids x], functions("SELECT a.x FROM active_ids() a")
    assert_equal ["active_ids"], functions("SELECT a.n FROM active_ids() AS a(n)")
    assert_equal %w[a active_ids], functions("SELECT a.a FROM active_ids() AS a(n)")
  end

  def test_built_in_function_columns
    assert_equal ["generate_series"], functions("SELECT g.g FROM generate_series(1, 3) g")
    assert_equal ["generate_series"], functions("SELECT t.t, t.ordinality FROM generate_series(1, 3) WITH ORDINALITY t")
    assert_equal ["jsonb_array_elements"], functions("SELECT e.value FROM jsonb_array_elements($1) e")
    assert_equal %w[e jsonb_array_elements], functions("SELECT e.e FROM jsonb_array_elements($1) e")
    assert_equal %w[g unnest], functions("SELECT g.g FROM unnest($1, $2) g")
  end

  def test_nothing_is_assumed_about_a_function_the_schema_does_not_describe
    schema = Pgsqlarbiter::Schema.new({"users" => %w[id]}, functions: {"report" => %w[month total]})
    analyze = ->(sql) { Pgsqlarbiter.analyze(sql, schema: schema).functions }
    assert_equal %w[g generate_series], analyze.call("SELECT g.g FROM generate_series(1, 3) g")
    assert_equal %w[g pg_catalog.generate_series], analyze.call("SELECT g.g FROM pg_catalog.generate_series(1, 3) g")
    assert_equal %w[jsonb_each key], analyze.call("SELECT e.key FROM jsonb_each($1) e")
    assert_equal %w[t to_tsvector unnest], analyze.call("SELECT t.t FROM unnest(to_tsvector('a')) t")
    assert_equal %w[ordinality unnest], analyze.call("SELECT t.ordinality FROM unnest($1) t")
    # The alias itself, a column alias list and WITH ORDINALITY do not depend on it.
    assert_equal ["generate_series"], analyze.call("SELECT g FROM generate_series(1, 3) g")
    assert_equal ["generate_series"], analyze.call("SELECT g.n FROM generate_series(1, 3) AS g(n)")
    assert_equal ["unnest"], analyze.call("SELECT t.v FROM unnest($1) AS t(v)")
    assert_equal ["unnest"], analyze.call("SELECT t.ordinality FROM unnest($1) WITH ORDINALITY t")
    assert_equal ["report"], analyze.call("SELECT r.month FROM report() r")
  end

  def test_function_declared_unknown
    assert_equal %w[l lower], functions("SELECT l.l FROM lower('x') l")
  end

  def test_undeclared_function_needs_a_column_list
    assert_equal %w[a mystery], functions("SELECT m.a FROM mystery() m")
    assert_equal ["mystery"], functions("SELECT m.a FROM mystery() AS m(a, b)")
    assert_equal ["mystery"], functions("SELECT a FROM mystery() AS m(a, b)")
    assert_equal ["mystery"], functions("SELECT m FROM mystery() m")
    assert_equal ["mystery"], functions("SELECT * FROM mystery()")
    assert_unresolved("SELECT a FROM mystery() m")
  end

  def test_xmltable_and_json_table_columns
    assert_equal ["xmltable"], functions("SELECT x.a, x.b FROM XMLTABLE('/r' PASSING $1 COLUMNS a int, b text) x")
    assert_equal %w[c xmltable], functions("SELECT x.c FROM XMLTABLE('/r' PASSING $1 COLUMNS a int, b text) x")
    sql = "SELECT j.%s FROM JSON_TABLE($1, '$[*]' COLUMNS (a int, NESTED '$.b' COLUMNS (c int))) j"
    assert_equal ["json_table"], functions(format(sql, "a"))
    assert_equal ["json_table"], functions(format(sql, "c"))
    assert_equal %w[d json_table], functions(format(sql, "d"))
  end

  # --- Bare names ---

  def test_bare_names_are_charged_to_every_table_that_has_them
    assert_equal ["users.name"], columns("SELECT name FROM users")
    assert_equal %w[orders.id users.id], columns("SELECT id FROM users, orders")
    assert_equal %w[orders.total users.name], columns("SELECT name, total FROM users, orders")
    assert_equal ["users.name"], columns("SELECT (SELECT name) FROM users")
    assert_equal ["users.tags"], columns("SELECT tags[1] FROM users")
  end

  def test_bare_name_that_is_not_found_is_refused
    assert_unresolved("SELECT ssn FROM users")
    assert_unresolved("SELECT 1 FROM users WHERE ssn = 'x'")
    assert_unresolved("SELECT 1 AS ssn FROM users WHERE ssn = 'x'")
    assert_unresolved("SELECT 1 AS ssn FROM users ORDER BY lower(ssn)")
    assert_unresolved("SELECT ssn FROM users, (SELECT 1 AS a) x")
    assert_unresolved("SELECT a")
    assert_unresolved("UPDATE users SET name = ssn")
  end

  def test_result_column_names_in_order_by_and_group_by
    assert_empty columns("SELECT 1 AS n FROM users ORDER BY n")
    assert_empty columns("SELECT 1 AS n FROM users GROUP BY n")
    assert_empty columns("SELECT 1 AS n FROM users ORDER BY (n)")
    assert_equal ["users.id"], columns("SELECT id AS n FROM users ORDER BY n DESC NULLS LAST")
    assert_equal ["users.id"], columns("SELECT id FROM users UNION SELECT id FROM users ORDER BY id")
    assert_equal %w[users.id users.name], columns("SELECT name AS id FROM users ORDER BY id")
  end

  def test_whole_row_references
    assert_equal ["users.*"], columns("SELECT u FROM users u")
    assert_equal ["users.*"], columns("SELECT users FROM users")
    assert_equal ["users.*"], columns("SELECT row_to_json(u) FROM users u")
    assert_equal ["users.*"], columns("SELECT count(u.*) FROM users u")
    assert_equal ["users.*"], columns("SELECT 1 FROM users u WHERE u IS NOT NULL")
    assert_equal ["users.*"], columns("SELECT (u).name FROM users u")
    assert_equal ["users.*"], columns("SELECT * FROM users")
    assert_equal ["users.*"], columns("SELECT u.* FROM users u")
    assert_equal ["users.*"], columns("TABLE users")
    assert_equal %w[orders.* users.*], columns("SELECT * FROM users, orders")
    assert_equal ["users.*"], columns("SELECT x.id FROM (SELECT * FROM users) x")
  end

  def test_queries_that_use_no_column
    assert_empty columns("SELECT count(*) FROM users")
    assert_empty columns("SELECT 1 FROM users")
    assert_empty columns("DELETE FROM users")
  end

  # --- Data-modifying statements ---

  def test_insert_columns
    assert_equal %w[users.id users.name], columns("INSERT INTO users (id, name) VALUES (1, 'a')")
    assert_equal ["users.*"], columns("INSERT INTO users VALUES (1, 'a')")
    assert_equal ["users.*"], columns("INSERT INTO users DEFAULT VALUES")
    assert_equal %w[orders.user_id users.id], columns("INSERT INTO users (id) SELECT user_id FROM orders")
    assert_equal %w[users.id users.tags], columns("INSERT INTO users (id, tags[1]) VALUES (1, 'a')")
  end

  def test_update_columns
    assert_equal %w[users.email users.id users.name], columns("UPDATE users SET name = email WHERE id = 1")
    assert_equal %w[users.email users.name], columns("UPDATE users SET (name, email) = ('a', 'b')")
    assert_equal %w[orders.total orders.user_id users.id users.name],
      columns("UPDATE users u SET name = o.total::text FROM orders o WHERE o.user_id = u.id")
  end

  def test_delete_columns
    assert_equal ["users.password_hash"], columns("DELETE FROM users WHERE password_hash IS NULL")
    assert_equal %w[orders.user_id users.id], columns("DELETE FROM users u USING orders o WHERE o.user_id = u.id")
  end

  def test_returning
    assert_equal %w[users.id users.password_hash], columns("DELETE FROM users WHERE id = 1 RETURNING password_hash")
    assert_equal ["users.*"], columns("DELETE FROM users RETURNING *")
    assert_equal ["users.*"], columns("DELETE FROM users u RETURNING u")
    assert_equal %w[users.name users.password_hash],
      columns("UPDATE users SET name = 'a' RETURNING old.password_hash")
    assert_equal %w[users.name users.password_hash],
      columns("UPDATE users SET name = 'a' RETURNING WITH (OLD AS before) before.password_hash")
    assert_equal ["secret_stuff"], functions("UPDATE users SET name = 'a' RETURNING new.secret_stuff")
    assert_equal ["users.*"], columns("DELETE FROM users RETURNING old")
  end

  def test_old_and_new_as_column_names
    assert_equal %w[notes.body notes.new notes.old], columns("UPDATE notes SET body = old WHERE new RETURNING old")
  end

  def test_on_conflict
    sql = "INSERT INTO users (id, name) VALUES (1, 'a') ON CONFLICT (email) DO UPDATE SET name = excluded.password_hash"
    assert_equal %w[users.email users.id users.name users.password_hash], columns(sql)
    assert_equal ["secret_stuff"],
      functions("INSERT INTO users (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET name = excluded.secret_stuff")
    assert_equal %w[users.id users.tags],
      columns("INSERT INTO users (id) VALUES (1) ON CONFLICT (id) WHERE tags IS NULL DO NOTHING")
  end

  def test_merge_columns
    sql = "MERGE INTO users u USING orders o ON u.id = o.user_id " \
          "WHEN MATCHED THEN UPDATE SET name = o.total::text " \
          "WHEN NOT MATCHED THEN INSERT (id, email) VALUES (o.user_id, 'x')"
    assert_equal %w[orders.total orders.user_id users.email users.id users.name], columns(sql)
    assert_equal %w[orders.user_id users.* users.id],
      columns("MERGE INTO users u USING orders o ON u.id = o.user_id WHEN NOT MATCHED THEN INSERT VALUES (o.user_id)")
    assert_equal ["secret_stuff"],
      functions("MERGE INTO users u USING orders o ON u.secret_stuff = o.id WHEN MATCHED THEN DELETE")
  end

  # --- Tables that are not in the schema ---

  def test_unknown_table_is_reported_and_its_columns_are_not_judged
    result = analyze("SELECT m.anything, other FROM missing m")
    assert_equal ["missing"], result.tables
    assert_empty result.functions
  end

  # --- Limits ---

  def test_resolution_work_is_bounded
    tables = (["users"] * 3000).each_with_index.map { |t, i| "#{t} u#{i}" }.join(", ")
    refs = (0...3000).map { |i| "u#{i}.id" }.join(", ")
    assert_equal ["users.id"], columns("SELECT #{refs} FROM #{tables}")
    nested = "SELECT * FROM #{"(SELECT * FROM " * 3000}users#{") x" * 3000}"
    assert_equal ["users.*"], columns(nested)
    error = assert_raises(Pgsqlarbiter::ParseError) do
      analyze("SELECT #{(["x.id"] * 3000).join(", ")} FROM #{(["users x"] * 3000).join(", ")}")
    end
    assert_match(/too complex/, error.message)
  end
end
