# frozen_string_literal: true

require_relative "../test_helper"

class TestSchema < Minitest::Test
  Schema = Pgsqlarbiter::Schema

  SCHEMA = Schema.new(
    {"users" => %w[id name email password_hash], "orders" => %w[id user_id total], :logs => [:id, :message]},
    functions: {"report" => %w[month total], "ids" => :scalar, "generate_series" => :unknown}
  )

  def arbiter(tables, **options)
    Pgsqlarbiter::Arbiter.new(schema: SCHEMA, allowed_statement_types: %i[select insert update delete merge],
      allowed_tables: tables, **options)
  end

  # --- Schema ---

  def test_tables_and_columns
    assert_equal %w[users orders logs], SCHEMA.tables
    assert SCHEMA.table?("users")
    refute SCHEMA.table?("public.users")
    assert_equal %w[id name email password_hash], SCHEMA.columns("users")
    assert_equal %w[id message], SCHEMA.columns("logs")
    assert_nil SCHEMA.columns("missing")
    assert SCHEMA.column?("users", "email")
    assert SCHEMA.column?("users", "ctid")
    refute SCHEMA.column?("users", "total")
    refute SCHEMA.column?("missing", "id")
    assert_includes SCHEMA.all_columns("users"), "xmin"
    assert_nil SCHEMA.all_columns("missing")
  end

  def test_functions
    assert_equal %w[month total], SCHEMA.function_columns("report")
    assert_equal :scalar, SCHEMA.function_columns("ids")
    assert_equal :unknown, SCHEMA.function_columns("generate_series")
    assert_nil SCHEMA.function_columns("missing")
  end

  def test_schema_is_frozen
    assert_predicate SCHEMA, :frozen?
    assert_predicate SCHEMA.columns("users"), :frozen?
    columns = %w[id]
    schema = Schema.new({"t" => columns})
    columns << "later"
    assert_equal %w[id], schema.columns("t")
  end

  def test_names_that_cannot_be_represented_are_rejected
    assert_raises(ArgumentError) { Schema.new({"t" => ["a.b"]}) }
    assert_raises(ArgumentError) { Schema.new({"t" => ["*"]}) }
    assert_raises(ArgumentError) { Schema.new({"t" => [""]}) }
    assert_raises(ArgumentError) { Schema.new({"" => []}) }
    assert_raises(ArgumentError) { Schema.new({"t" => "id"}) }
    assert_raises(ArgumentError) { Schema.new({"t" => [1]}) }
    assert_raises(ArgumentError) { Schema.new(["t"]) }
    assert_raises(ArgumentError) { Schema.new({}, functions: {"f" => "scalar"}) }
    assert_raises(ArgumentError) { Schema.new({}, functions: {"f" => ["a.b"]}) }
  end

  def test_load_from_the_catalog_document
    json = '{"tables": {"users": ["id", "name"], "public.users": ["id", "name"]}, ' \
           '"functions": {"report": ["month", "total"], "ids": "scalar", "unnest": null}}'
    schema = Schema.load(json)
    assert_equal %w[id name], schema.columns("public.users")
    assert_equal %w[month total], schema.function_columns("report")
    assert_equal :scalar, schema.function_columns("ids")
    assert_equal :unknown, schema.function_columns("unnest")
    assert_equal %w[id name], Schema.load({"tables" => {"users" => %w[id name]}}).columns("users")
    assert_raises(ArgumentError) { Schema.load("[]") }
  end

  def test_schema_is_required
    assert_raises(ArgumentError) { Pgsqlarbiter.analyze("SELECT 1") }
    assert_raises(ArgumentError) { Pgsqlarbiter.analyze("SELECT 1", schema: {"users" => %w[id]}) }
    assert_raises(ArgumentError) { Pgsqlarbiter.allow?("SELECT 1", allowed_tables: []) }
    assert_raises(ArgumentError) do
      Pgsqlarbiter::Arbiter.new(schema: nil, allowed_statement_types: [:select], allowed_tables: [])
    end
  end

  # --- Whitelists must agree with the schema ---

  def test_allowed_table_must_be_in_the_schema
    error = assert_raises(ArgumentError) { arbiter(%w[users missing]) }
    assert_match(/"missing" is not in the schema/, error.message)
    assert_raises(ArgumentError) { arbiter({"missing" => :all}) }
  end

  def test_allowed_column_must_be_in_the_schema
    error = assert_raises(ArgumentError) { arbiter({"users" => %w[id nmae]}) }
    assert_match(/"nmae"/, error.message)
    assert_raises(ArgumentError) { arbiter({"users" => "id"}) }
    assert_raises(ArgumentError) { arbiter({"users" => nil}) }
  end

  def test_table_missing_from_the_schema_is_denied
    verdict = arbiter(["users"]).judge("SELECT m.x FROM missing m")
    refute verdict.allowed?
    assert_equal ["missing"], verdict.disallowed_tables
  end

  # --- Column restrictions ---

  def test_array_of_tables_allows_every_column
    a = arbiter(%w[users orders])
    assert_equal Set["users", "orders"], a.allowed_tables
    assert_equal({"users" => :all, "orders" => :all}, a.allowed_columns)
    assert a.allow?("SELECT * FROM users")
    assert a.allow?("SELECT password_hash FROM users u JOIN orders o ON o.user_id = u.id")
  end

  def restricted
    arbiter({"users" => %w[id name email], "orders" => :all})
  end

  def assert_denied_columns(expected, sql)
    verdict = restricted.judge(sql)
    refute verdict.allowed?, sql
    assert_equal expected, verdict.disallowed_columns, sql
    assert_empty verdict.disallowed_tables, sql
    assert_empty verdict.disallowed_functions, sql
  end

  def test_allowed_columns_pass
    a = restricted
    assert_equal Set["users", "orders"], a.allowed_tables
    assert_equal Set["id", "name", "email"], a.allowed_columns["users"]
    assert a.allow?("SELECT id, name FROM users")
    assert a.allow?("SELECT u.id, u.email, o.* FROM users u JOIN orders o ON o.user_id = u.id")
    assert a.allow?("SELECT count(*) FROM users")
    assert a.allow?("SELECT name FROM users WHERE email LIKE 'a%' ORDER BY id")
    assert a.allow?("SELECT x.name FROM (SELECT id, name FROM users) x")
    assert a.allow?("SELECT * FROM (SELECT id, name FROM users) x")
    assert a.allow?("SELECT u.id FROM users u JOIN orders o USING (id)")
    assert a.allow?("SELECT * FROM orders")
    assert a.allow?("INSERT INTO users (id, name) VALUES (1, 'a')")
    assert a.allow?("UPDATE users SET name = 'b' WHERE id = 1 RETURNING id, email")
    assert a.allow?("DELETE FROM users WHERE id = 1")
  end

  def test_restricted_column_is_denied_wherever_it_is_used
    hash = ["users.password_hash"]
    assert_denied_columns hash, "SELECT password_hash FROM users"
    assert_denied_columns hash, "SELECT u.password_hash FROM users u"
    assert_denied_columns hash, "SELECT id FROM users WHERE password_hash LIKE 'a%'"
    assert_denied_columns hash, "SELECT id FROM users ORDER BY password_hash"
    assert_denied_columns hash, "SELECT id FROM users GROUP BY id, password_hash"
    assert_denied_columns hash, "SELECT max(password_hash) FROM users"
    assert_denied_columns hash, "SELECT x.h FROM (SELECT password_hash AS h FROM users) x"
    assert_denied_columns hash, "WITH c AS (SELECT password_hash AS h FROM users) SELECT h FROM c"
    assert_denied_columns hash, "SELECT o.id FROM orders o WHERE EXISTS (SELECT 1 FROM users u WHERE u.password_hash = o.id::text)"
    assert_denied_columns hash, "SELECT (SELECT password_hash FROM users LIMIT 1)"
    assert_denied_columns hash, "SELECT 1 FROM orders o JOIN users u ON u.password_hash = 'x'"
    assert_denied_columns hash, "SELECT o.id FROM orders o, LATERAL (SELECT password_hash FROM users) x"
    assert_denied_columns hash, "UPDATE users SET password_hash = 'x'"
    assert_denied_columns hash, "UPDATE users SET name = password_hash"
    assert_denied_columns hash, "UPDATE users SET name = 'x' RETURNING old.password_hash"
    assert_denied_columns hash, "INSERT INTO users (id, password_hash) VALUES (1, 'x')"
    assert_denied_columns hash, "INSERT INTO users (id) VALUES (1) ON CONFLICT (id) DO UPDATE SET name = excluded.password_hash"
    assert_denied_columns hash, "DELETE FROM users WHERE password_hash IS NULL"
    assert_denied_columns hash, "DELETE FROM users RETURNING password_hash"
    assert_denied_columns hash, "MERGE INTO users u USING orders o ON u.id = o.id WHEN MATCHED THEN UPDATE SET password_hash = 'x'"
  end

  def test_system_columns_are_restricted_too
    assert_denied_columns ["users.ctid"], "SELECT ctid FROM users"
    assert arbiter({"users" => %w[id ctid]}).allow?("SELECT ctid FROM users")
  end

  def test_every_column_at_once_is_denied_on_a_restricted_table
    all = ["users.*"]
    assert_denied_columns all, "SELECT * FROM users"
    assert_denied_columns all, "SELECT u.* FROM users u"
    assert_denied_columns all, "TABLE users"
    assert_denied_columns all, "SELECT u FROM users u"
    assert_denied_columns all, "SELECT to_jsonb(u) FROM users u"
    assert_denied_columns all, "SELECT count(u) FROM users u"
    assert_denied_columns all, "SELECT x.id FROM (SELECT * FROM users) x"
    assert_denied_columns all, "SELECT 1 FROM users NATURAL JOIN orders"
    assert_denied_columns all, "SELECT a FROM users AS u(a, b)"
    assert_denied_columns all, "SELECT j FROM (users u JOIN orders o ON true) AS j"
    assert_denied_columns all, "INSERT INTO users VALUES (1)"
    assert_denied_columns all, "INSERT INTO users DEFAULT VALUES"
    assert_denied_columns all, "DELETE FROM users RETURNING *"
    assert_denied_columns all, "UPDATE users SET name = 'x' RETURNING users"
  end

  def test_function_call_hidden_as_a_column_is_denied
    verdict = restricted.judge("SELECT u.secret_stuff FROM users u")
    refute verdict.allowed?
    assert_equal ["secret_stuff"], verdict.disallowed_functions
    assert_equal ["users.*"], verdict.disallowed_columns
    verdict = arbiter(["users"]).judge("SELECT u.secret_stuff FROM users u")
    assert_equal ["secret_stuff"], verdict.disallowed_functions
    assert_empty verdict.disallowed_columns
    assert arbiter(["users"], allowed_functions: ["secret_stuff"]).allow?("SELECT u.secret_stuff FROM users u")
  end

  def test_columns_of_a_disallowed_table_are_not_reported_separately
    verdict = arbiter({"orders" => %w[id]}).judge("SELECT password_hash FROM users")
    assert_equal ["users"], verdict.disallowed_tables
    assert_empty verdict.disallowed_columns
  end

  def test_reasons
    verdict = restricted.judge("SELECT password_hash FROM users")
    assert_equal ['column "users.password_hash" is not allowed'], verdict.reasons
    verdict = restricted.judge("SELECT * FROM users")
    assert_equal 1, verdict.reasons.length
    assert_match(/every column of table "users".*restricted/, verdict.reasons[0])
  end

  def test_verdict_built_without_disallowed_columns
    verdict = Pgsqlarbiter::Verdict.new(allowed: true, statement_type_allowed: true, statement_type: :select,
      disallowed_tables: [], disallowed_functions: [])
    assert_empty verdict.disallowed_columns
  end

  def test_module_methods_take_column_restrictions
    assert Pgsqlarbiter.allow?("SELECT id FROM users", schema: SCHEMA, allowed_tables: {"users" => %w[id]})
    verdict = Pgsqlarbiter.judge("SELECT name FROM users", schema: SCHEMA, allowed_tables: {"users" => %w[id]})
    assert_equal ["users.name"], verdict.disallowed_columns
  end
end
