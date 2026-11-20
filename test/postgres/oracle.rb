# frozen_string_literal: true

# Checks pgsqlarbiter against a live PostgreSQL server.
#
#   rake test:postgres          (connection from the usual PG* environment variables)
#
# For every query in corpus.sql the server is asked, through the dependency
# records of a temporary view, which user tables, functions and types the query
# and columns the query really uses. pgsqlarbiter, given a schema loaded from the
# same server with Pgsqlarbiter::Schema::QUERY, must have reported every one of
# them, or have refused the query. Nothing is executed and the view is rolled back; the only
# lasting change is a schema called pgsqlarbiter_oracle, which is dropped and
# recreated on each run.
#
# Queries in the corpus are separated by a line of four dashes. A query may be
# preceded by one marker line:
#
#   @refused    Valid SQL that pgsqlarbiter refuses on purpose.
#   @invalid    PostgreSQL itself rejects the query.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "pgsqlarbiter"
require "open3"

SCHEMA = "pgsqlarbiter_oracle"

def psql(sql)
  out, status = Open3.capture2e("psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql)
  [status.success?, out.strip]
end

ok, out = psql(<<~SQL)
  SET client_min_messages = warning;
  DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE;
  CREATE SCHEMA #{SCHEMA};
  SET search_path = #{SCHEMA};
  CREATE TABLE users(id int, name text, tags text[], data jsonb);
  CREATE TABLE secrets(id int, secret text);
  CREATE TABLE orders(id int, user_id int, amount numeric);
  CREATE TYPE secret_type AS (a int, b text);
  CREATE FUNCTION danger() RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION danger(int) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION danger(text) RETURNS text LANGUAGE sql AS 'select $1';
  CREATE FUNCTION danger_row(users) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION danger_any(anyelement) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION danger_set() RETURNS SETOF int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION first(int) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION filter(int) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE AGGREGATE danger_agg(int) (sfunc = int4pl, stype = int);
  CREATE FUNCTION report() RETURNS TABLE(month int, total int) LANGUAGE sql AS 'select 1, 2';
  CREATE FUNCTION pair(OUT a int, OUT b text) LANGUAGE sql AS $$select 1, 'x'$$;
  CREATE FUNCTION one_secret() RETURNS secrets LANGUAGE sql AS 'select * from secrets limit 1';
  CREATE FUNCTION scalar_fn() RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION single_out(OUT v int) LANGUAGE sql AS 'select 1';
  CREATE FUNCTION month(anyelement) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION g(anyelement) RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION email(users) RETURNS text LANGUAGE sql AS $$select 'x'$$;
  CREATE VIEW user_names AS SELECT id, name FROM users;
SQL
abort "could not set up the #{SCHEMA} schema (is PostgreSQL reachable through PG* variables?):\n#{out}" unless ok

ok, document = psql("SET search_path = #{SCHEMA}; #{Pgsqlarbiter::Schema::QUERY}")
abort "could not read the schema:\n#{document}" unless ok
DATABASE = Pgsqlarbiter::Schema.load(document)
abort "schema query returned no tables:\n#{document}" unless DATABASE.table?("users") && DATABASE.table?("#{SCHEMA}.users")

# What the catalog query says about functions, PostgreSQL's own included.
{
  "generate_series" => :scalar, "pg_catalog.generate_series" => :scalar, "regexp_split_to_table" => :scalar,
  "jsonb_array_elements" => %w[value], "jsonb_each" => %w[key value], "pg_catalog.json_each_text" => %w[key value],
  "ts_stat" => %w[word ndoc nentry],
  # unnest(anyarray) returns whatever the array holds, unnest(tsvector) three columns.
  "unnest" => nil, "pg_catalog.unnest" => nil,
  # lower(text) and lower(anyrange) differ; json_to_record returns an undeclared row.
  "lower" => nil, "json_to_record" => nil, "pg_sleep" => nil,
  "report" => %w[month total], "#{SCHEMA}.report" => %w[month total], "pair" => %w[a b],
  "scalar_fn" => :scalar, "single_out" => %w[v], "one_secret" => %w[id secret],
  # danger() and danger(int) return a value, danger(text) too: all scalar.
  "danger" => :scalar, "danger_set" => :scalar, "danger_any" => :scalar
}.each do |function, expected|
  actual = DATABASE.function_columns(function)
  abort "schema query: #{function} should be #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

# The rule behind those answers, checked for every function that can be called
# with NULL arguments: a view over "SELECT * FROM f(...) AS zz" has the columns
# the server really gives the function in FROM.
ok, out = psql(<<~SQL)
  SET client_min_messages = warning;
  SET search_path = #{SCHEMA};
  CREATE TEMP TABLE shape_result(proname text, signature text, columns text);
  DO $shape$
  DECLARE f record; found text;
  BEGIN
    FOR f IN SELECT p.proname, p.oid::regprocedure::text AS signature,
                    (SELECT coalesce(string_agg('NULL::' || format_type(t, NULL), ', ' ORDER BY o), '')
                       FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY a(t, o)) AS arguments
               FROM pg_proc p WHERE p.prokind = 'f' AND pg_function_is_visible(p.oid) LOOP
      BEGIN
        EXECUTE format('CREATE TEMP VIEW shape_view AS SELECT * FROM %I(%s) AS zz', f.proname, f.arguments);
        SELECT string_agg(attname, ',' ORDER BY attnum) INTO found
          FROM pg_attribute WHERE attrelid = 'pg_temp.shape_view'::regclass AND attnum > 0;
        DROP VIEW shape_view;
        INSERT INTO shape_result VALUES (f.proname, f.signature, found);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;
  END $shape$;
  SELECT proname || E'\t' || signature || E'\t' || columns FROM shape_result;
SQL
abort "could not check function result columns:\n#{out}" unless ok
shapes = out.lines.map { |l| l.chomp.split("\t") }.select { |fields| fields.length == 3 }
described = shapes.select { |name, _, _| DATABASE.function_columns(name) }
abort "too few functions could be checked (#{described.length})" if described.length < 2000
described.each do |name, signature, columns|
  declared = DATABASE.function_columns(name)
  expected = (declared == :scalar) ? ["zz"] : declared
  unless columns.split(",") == expected
    abort "schema query: #{signature} returns #{columns} in FROM, but the schema says #{declared.inspect}"
  end
end
puts "#{described.length} function signatures: result columns agree with the server"

DEPENDENCIES = <<~SQL
  SELECT CASE d.refclassid
           WHEN 'pg_class'::regclass THEN
             CASE WHEN d.refobjsubid > 0
                  THEN 'column:' || (SELECT relname FROM pg_class WHERE oid = d.refobjid) || '.' ||
                       (SELECT attname FROM pg_attribute WHERE attrelid = d.refobjid AND attnum = d.refobjsubid)
                  ELSE 'table:' || (SELECT relname FROM pg_class WHERE oid = d.refobjid) END
           WHEN 'pg_proc'::regclass THEN 'function:' || (SELECT proname FROM pg_proc WHERE oid = d.refobjid)
           WHEN 'pg_type'::regclass THEN 'type:' || (SELECT typname FROM pg_type WHERE oid = d.refobjid)
           ELSE 'other:' || d.refclassid::regclass::text END
  FROM pg_depend d JOIN pg_rewrite r ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
  WHERE r.ev_class = 'pg_temp.oracle_view'::regclass AND d.refobjid <> 'pg_temp.oracle_view'::regclass
SQL

def server_dependencies(sql)
  ok, out = psql("SET search_path = #{SCHEMA}; BEGIN; CREATE TEMP VIEW oracle_view AS #{sql}\n; #{DEPENDENCIES}; ROLLBACK")
  return [false, out[/ERROR:.*/].to_s] unless ok

  [true, out.split("\n").map(&:strip).reject(&:empty?).uniq.sort]
end

def reported(sql)
  analysis = Pgsqlarbiter.analyze(sql, schema: DATABASE)
  last = ->(name) { name.split(".").last }
  columns = analysis.columns.map do |c|
    table, _, column = c.rpartition(".")
    "column:#{last.call(table)}.#{column}"
  end
  # A composite type and its table share a name, so a reported type also
  # accounts for a dependency on the relation of that name.
  analysis.tables.map { |t| "table:#{last.call(t)}" } +
    analysis.functions.map { |f| "function:#{last.call(f)}" } +
    analysis.types.flat_map { |t| ["type:#{last.call(t)}", "table:#{last.call(t)}"] } + columns
rescue Pgsqlarbiter::Error => e
  e
end

entries = File.read(File.join(__dir__, "corpus.sql"), encoding: "UTF-8").split(/^----\n/).map(&:strip).reject(&:empty?)
failures = []
counts = Hash.new(0)

entries.each do |entry|
  marker = entry[/\A@([\w-]+)\n/, 1]
  sql = entry.sub(/\A@[\w-]+\n/, "")
  sql = sql.gsub("\\r", "\r").gsub(/\\u(\h{4})/) { [$1.hex].pack("U") }
  fail_with = ->(message) { failures << "#{message}\n    #{sql.inspect}" }

  valid, dependencies = server_dependencies(sql)
  ours = reported(sql)

  if !valid
    counts["rejected by PostgreSQL"] += 1
    fail_with.call("PostgreSQL rejected a query not marked @invalid: #{dependencies}") unless marker == "invalid"
  elsif marker == "invalid"
    fail_with.call("marked @invalid but PostgreSQL accepted it")
  elsif ours.is_a?(Exception)
    counts["refused by pgsqlarbiter"] += 1
    fail_with.call("pgsqlarbiter refused valid SQL: #{ours.class}: #{ours.message}") unless marker == "refused"
  elsif marker == "refused"
    fail_with.call("marked @refused but pgsqlarbiter analyzed it")
  else
    # "table.*" stands for every column of the table. A column of a composite
    # type's own relation is covered by the type.
    # A row passed to a function may be converted to the function's row
    # type, which is the type of a table that was reported.
    missing = (dependencies - ours).reject do |dependency|
      next ours.include?("table:#{dependency.delete_prefix("type:")}") if dependency.start_with?("type:")
      next false unless dependency.start_with?("column:")

      table = dependency.delete_prefix("column:").rpartition(".").first
      ours.include?("column:#{table}.*") || ours.include?("type:#{table}")
    end
    if missing.empty?
      counts["agreed"] += 1
    else
      fail_with.call("MISSED #{missing.join(", ")} (PostgreSQL: #{dependencies.join(", ")})")
    end
  end
end

psql("DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE")
puts "#{entries.size} queries: " + counts.sort.map { |k, v| "#{v} #{k}" }.join(", ")
unless failures.empty?
  puts failures.map { |f| "  #{f}" }
  abort "#{failures.size} failure(s)"
end
