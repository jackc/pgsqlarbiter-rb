# frozen_string_literal: true

require_relative "../test_helper"

class TestTypesAndStatementTypes < Minitest::Test
  def analyze(sql)
    Pgsqlarbiter.analyze(sql, schema: EMPTY_SCHEMA)
  end

  # --- Canonical type names ---

  def test_keyword_types_have_one_name_per_type
    {
      "int" => "integer", "integer" => "integer", "smallint" => "smallint", "bigint" => "bigint",
      "real" => "real", "float" => "float", "float(8)" => "float", "double precision" => "double precision",
      "decimal" => "numeric", "dec(5)" => "numeric", "numeric(10, 2)" => "numeric", "boolean" => "boolean",
      "bit" => "bit", "bit(3)" => "bit", "bit varying" => "bit varying", "bit varying(5)" => "bit varying",
      "char" => "character", "character(5)" => "character", "nchar" => "character",
      "national character(3)" => "character", "varchar" => "character varying", "varchar(10)" => "character varying",
      "character varying(10)" => "character varying", "char varying" => "character varying",
      "national char varying(3)" => "character varying",
      "time" => "time", "time(3)" => "time", "time without time zone" => "time",
      "time with time zone" => "time with time zone",
      "timestamp" => "timestamp", "timestamp(3) without time zone" => "timestamp",
      "timestamp with time zone" => "timestamp with time zone",
      "timestamp(6) with time zone" => "timestamp with time zone",
      "interval" => "interval", "interval day to second" => "interval", "interval(3)" => "interval", "json" => "json"
    }.each do |written, canonical|
      assert_equal [canonical], analyze("SELECT x::#{written} FROM t").types, written
      assert_equal [canonical], analyze("SELECT CAST(x AS #{written}) FROM t").types, written
    end
  end

  def test_other_types_are_recorded_as_written
    assert_equal %w[int4 text timestamptz], analyze("SELECT a::int4, b::TEXT, c::TimestampTZ FROM t").types
    assert_equal ["MyType"], analyze('SELECT a::"MyType" FROM t').types
    assert_equal ["pg_catalog.int4"], analyze("SELECT a::pg_catalog.int4 FROM t").types
    assert_equal ["db.s.t"], analyze("SELECT a::db.s.t FROM t").types
  end

  def test_array_types_are_recorded_as_their_element_type
    assert_equal ["integer"], analyze("SELECT a::int[], b::integer ARRAY, c::int[3][3] FROM t").types
    assert_equal ["text"], analyze("SELECT ARRAY[]::text[]").types
  end

  def test_typed_literals
    assert_equal ["date"], analyze("SELECT date '2020-01-01'").types
    assert_equal ["timestamp with time zone"], analyze("SELECT timestamp with time zone '2020-01-01'").types
    assert_equal ["interval"], analyze("SELECT interval '1' day, interval(3) '1'").types
    assert_equal ["double precision"], analyze("SELECT double precision '1.5'").types
    assert_equal ["character"], analyze("SELECT N'x', char 'y'").types
    assert_equal ["json"], analyze("SELECT json '{}'").types
  end

  def test_quoted_type_name_containing_a_dot_is_refused
    assert_raises(Pgsqlarbiter::ParseError) { analyze('SELECT a::"my.type" FROM t') }
  end

  def test_query_without_types
    assert_empty analyze("SELECT a, count(*) FROM t GROUP BY a").types
  end

  # --- Arbiter ---

  def test_default_types_cover_ordinary_casts
    sql = "SELECT id::text, created_at::date, age::numeric(10, 2), active::bool, data::jsonb, created_at::timestamptz, " \
          "id::int, id::bigint, age::double precision, name::uuid, name::varchar(20), age::interval FROM users"
    assert Pgsqlarbiter.allow?(sql, schema: TEST_SCHEMA, allowed_tables: ["users"])
  end

  def test_disallowed_type_is_reported
    verdict = Pgsqlarbiter.judge("SELECT 'users'::regclass", schema: TEST_SCHEMA, allowed_tables: [])
    refute verdict.allowed?
    assert_equal ["regclass"], verdict.disallowed_types
    assert_equal ['type "regclass" is not allowed'], verdict.reasons
    assert verdict.statement_type_allowed?
  end

  def test_custom_allowed_types
    arbiter = Pgsqlarbiter::Arbiter.new(
      allowed_statement_types: [:select], schema: TEST_SCHEMA, allowed_tables: ["t"],
      allowed_types: Pgsqlarbiter::DEFAULT_QUERY_TYPES | ["mood"]
    )
    assert arbiter.allow?("SELECT x::mood FROM t")
    refute arbiter.allow?("SELECT x::regclass FROM t")
    assert_includes arbiter.allowed_types, "mood"
    assert arbiter.allowed_types.frozen?

    strict = Pgsqlarbiter::Arbiter.new(allowed_statement_types: [:select], schema: TEST_SCHEMA, allowed_tables: ["t"], allowed_types: [])
    refute strict.allow?("SELECT x::int FROM t")
    assert strict.allow?("SELECT x FROM t")
  end

  def test_object_identifier_types_are_not_default
    %w[regclass regproc regprocedure regtype regnamespace regrole regoper regoperator regconfig
      regdictionary regcollation oid name].each do |type|
      refute_includes Pgsqlarbiter::DEFAULT_QUERY_TYPES, type
    end
    assert Pgsqlarbiter::DEFAULT_QUERY_TYPES.frozen?
  end

  # --- Statement types ---

  def test_statement_types_of_plain_statements
    assert_equal [:select], analyze("SELECT 1").statement_types
    assert_equal [:values], analyze("VALUES (1)").statement_types
    assert_equal [:insert], analyze("INSERT INTO t SELECT * FROM s").statement_types
    assert_equal [:insert], analyze("INSERT INTO t VALUES (1)").statement_types
    assert_equal [:update], analyze("UPDATE t SET a = (SELECT 1)").statement_types
    assert_equal [:delete], analyze("WITH x AS (SELECT 1) DELETE FROM t").statement_types
    assert_equal [:merge], analyze("MERGE INTO t USING s ON true WHEN MATCHED THEN DELETE").statement_types
  end

  def test_values_statement_type
    assert_equal :values, analyze("VALUES (1), (2) ORDER BY 1 LIMIT 1").statement_type
    assert_equal :values, analyze("(VALUES (1))").statement_type
    assert_equal :values, analyze("WITH x AS (SELECT 1) VALUES (1)").statement_type
    assert_equal :select, analyze("VALUES (1) UNION SELECT 2").statement_type
    assert_equal :select, analyze("SELECT * FROM (VALUES (1)) v").statement_type
  end

  def test_select_written_other_ways
    assert_equal :select, analyze("TABLE t").statement_type
    assert_equal :select, analyze("(SELECT 1)").statement_type
    assert_equal :select, analyze("((SELECT 1) UNION (SELECT 2))").statement_type
  end

  def test_verdict_lists_every_disallowed_statement_type
    sql = "WITH a AS (DELETE FROM t RETURNING *), b AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM a FOR UPDATE"
    verdict = Pgsqlarbiter.judge(sql, schema: TEST_SCHEMA, allowed_tables: ["t"], allowed_statement_types: [:select])
    refute verdict.allowed?
    refute verdict.statement_type_allowed?
    assert_equal :select, verdict.statement_type
    assert_equal [:delete, :insert, :update], verdict.disallowed_statement_types
    assert_equal ["statement type :delete is not allowed", "statement type :insert is not allowed",
      "statement type :update is not allowed"], verdict.reasons
  end

  def test_verdict_built_without_the_new_fields
    verdict = Pgsqlarbiter::Verdict.new(allowed: false, statement_type_allowed: false, statement_type: :insert,
      disallowed_tables: [], disallowed_functions: [])
    assert_equal [:insert], verdict.disallowed_statement_types
    assert_empty verdict.disallowed_types
    assert_equal ["statement type :insert is not allowed"], verdict.reasons
  end

  # --- The parser runtime is private ---

  def test_parser_runtime_does_not_define_global_racc
    out = IO.popen([RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e",
      'require "pgsqlarbiter"; Pgsqlarbiter.analyze("SELECT 1", schema: Pgsqlarbiter::Schema.new({})); ' \
      'print [defined?(::Racc).inspect, $LOADED_FEATURES.grep(/racc/).length].join(",")'], &:read)
    assert_equal "nil,0", out
  end
end
