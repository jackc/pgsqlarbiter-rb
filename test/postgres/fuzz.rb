# frozen_string_literal: true

# Fuzzes pgsqlarbiter's lexer against a live PostgreSQL server.
#
#   rake test:postgres_fuzz                 (connection from PG* variables)
#   ruby test/postgres/fuzz.rb COUNT SEED
#
# Builds queries out of lexically awkward fragments (quotes, dollar quotes,
# comments, operators, escapes, carriage returns) placed around a reference to
# a table and a function. Whether that reference is live code or is buried in a
# string or comment depends entirely on where each token ends. For every query
# PostgreSQL accepts, its dependency records say which it was, and pgsqlarbiter
# must have reported at least as much. Nothing is executed.
#
# The whole batch is one round trip: queries are sent hex-encoded and a DO
# block tries each as a temporary view.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "pgsqlarbiter"
require "open3"

count = (ARGV[0] || 5000).to_i
seed = (ARGV[1] || Random.new_seed % 1_000_000).to_i
rng = Random.new(seed)
SCHEMA = "pgsqlarbiter_fuzz"
DATABASE = Pgsqlarbiter::Schema.new({"secrets" => ["id", "secret", "c1", 'a"b', "é", "C1", "c$1", "c$x$"]})

ATOMS = [
  "1", "42", "1.5", ".5", "1.", "1e3", "0x1F", "1_000", "'a'", "'a''b'", "''", "E'a\\'b'", "E'\\\\'", "e'\\''", "'\\'", "'a\\'", "'\\\\'",
  "$$x$$", "$$$$", "$t$ ' $$ $t$", "$t$ $T$ $t$", "B'1'", "X'1F'", "U&'\\0061'", "U&'a'", "N'a'",
  "'a'\n'b'", "'a'\r'b'", "E'a'\n'\\' x'", "'a' --c\n 'b'", "'a'\n--c\n'b'", "'a' \t\f\v\n 'b'",
  "c1", "\"c1\"", "\"a\"\"b\"", "C1", "c$1", "c$x$", "U&\"c1\"", "U&\"\\0063\\0031\"", "$1", "é", "\"é\"",
  "(1)", "(1, 2)", "ARRAY[1]", "NULL", "TRUE", "1::int", "CAST(1 AS int)", "- 1", "+1", "@ 1", "'x'::text"
].freeze

OPERATORS = [
  "+", "-", "*", "/", "%", "^", "<", ">", "=", "<=", ">=", "<>", "!=", "||", "<->", "@-", "!=-", "*-", "<>-", ">=+",
  "+-", "- -", "--1\n+", "-/**/-", "+/*x*/", "+--\n", "+--\r", "/* */+", "<-", "=-", "~", "!~", "&&", "|/", "#", "@@",
  " AND ", " OR ", " IS NOT DISTINCT FROM ", " NOT IN ", "::text||", ".", "..", ":", ":=", "=>",
  "+/*'*/", "-/*$$*/", "||/*\"*/", "*/*--*/", "+--'\n", "- --$$\r", "</*E'*/", "+/*/**/'*/"
].freeze

NOISE = [
  " ", "\n", "\r", "\t", "\f", "\v", "\r\n", "--", "--x\n", "--x\r", "--'\n", "--'\r", "--$$\n", "--$$\r", "--/*\n",
  "/* x */", "/* /* y */ */", "/*'*/", "/*$$*/", "/*--*/", "/**/", "/*/ */", "/*", "*/", "'", "''", "\"", "$$", "$t$",
  "$", "\\", "\\'", "E'", "e'", "U&'", "U&\"", "B'", "N'", ";", "(", ")", ",", "-", "/", "*", "+", "a", "1", "é",
  "E'\\'", "'\\'", "$a$x$a$", "a$a$", "1$$", "$1$$", "'\n'", "'\r'", "' --\n '", "' /*", "*/ '", "--\r'", "x'", "b'",
  "+/*", "-/*'", "+--", "|/*$$", "/*+", "*/-", "@/*", "\u00e9$$", "$\u00e9$", "$$\u00e9$$", "'\u00e9'"
].freeze

pick = ->(list) { list[rng.rand(list.length)] }
glue = -> { (rng.rand(3) == 0) ? "" : pick.call([" ", " ", "\n", "\r", "\t", " /* c */ ", " --c\n", " --c\r"]) }
expr = lambda do
  parts = [pick.call(ATOMS)]
  rng.rand(3).times { parts << glue.call << pick.call(OPERATORS) << glue.call << pick.call(ATOMS) }
  parts.join
end
noise = lambda do
  n = rng.rand(4)
  (0...n).map { pick.call(NOISE) }.join((rng.rand(2) == 0) ? "" : " ")
end

queries = Array.new(count) do
  case rng.rand(6)
  when 0 then "SELECT #{expr.call} AS k1, secret FROM secrets"
  when 1 then "SELECT #{expr.call} AS k1 #{noise.call}, secret FROM secrets #{noise.call}"
  when 2 then "SELECT #{expr.call} AS k1#{noise.call}, danger() AS k2 #{noise.call}"
  when 3 then "SELECT 1 AS k1 #{noise.call} FROM secrets #{noise.call}"
  when 4 then "SELECT #{noise.call} #{expr.call} AS k1, danger() AS k2, #{expr.call} AS k3 #{noise.call} FROM secrets"
  else "SELECT #{expr.call}#{noise.call}#{expr.call} AS k1 #{noise.call} FROM secrets s#{noise.call}, secrets"
  end
end

script = +<<~SQL
  \\set ON_ERROR_STOP 1
  SET client_min_messages = warning;
  DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE;
  CREATE SCHEMA #{SCHEMA};
  SET search_path = #{SCHEMA};
  CREATE TABLE secrets(id int, secret text, c1 int, "a""b" int, "é" int, "C1" int, c$1 int, c$x$ int);
  CREATE FUNCTION danger() RETURNS int LANGUAGE sql AS 'select 1';
  CREATE TEMP TABLE fuzz_query(i int, hex text);
  CREATE TEMP TABLE fuzz_result(i int, state text, deps text);
  COPY fuzz_query FROM stdin;
SQL
queries.each_with_index { |q, i| script << "#{i}\t#{q.unpack1("H*")}\n" }
script << "\\.\n"
# One DO block per batch: each is its own transaction, so the locks taken by
# creating and dropping a view are released before the server runs out of them.
BATCH = 500
(0...count).step(BATCH) do |from|
  script << format(<<~'SQL', from: from, to: from + BATCH)
  DO $fuzz$
  DECLARE q record; found text;
  BEGIN
    FOR q IN SELECT * FROM fuzz_query WHERE i >= %{from} AND i < %{to} ORDER BY i LOOP
      BEGIN
        EXECUTE 'CREATE TEMP VIEW fuzz_view AS ' || convert_from(decode(q.hex, 'hex'), 'UTF8') || E'\n';
        SELECT coalesce(string_agg(DISTINCT CASE d.refclassid
                 WHEN 'pg_class'::regclass THEN 'table:' || (SELECT relname FROM pg_class WHERE oid = d.refobjid)
                 WHEN 'pg_proc'::regclass THEN 'function:' || (SELECT proname FROM pg_proc WHERE oid = d.refobjid)
                 ELSE 'other' END, ' '), '')
          INTO found
          FROM pg_depend d JOIN pg_rewrite r ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
         WHERE r.ev_class = 'pg_temp.fuzz_view'::regclass AND d.refobjid <> 'pg_temp.fuzz_view'::regclass;
        DROP VIEW fuzz_view;
        INSERT INTO fuzz_result VALUES (q.i, 'ok', found);
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO fuzz_result VALUES (q.i, SQLSTATE, '');
      END;
    END LOOP;
  END
  $fuzz$;
  SQL
end
script << <<~SQL
  SELECT i, state, deps FROM fuzz_result ORDER BY i;
  DROP SCHEMA #{SCHEMA} CASCADE;
SQL

out, status = Open3.capture2e("psql", "-X", "-q", "-A", "-t", "-F", "\t", "-f", "-", stdin_data: script)
abort "psql failed (is PostgreSQL reachable through PG* variables?):\n#{out[0, 2000]}" unless status.success?

results = out.lines.map { |l| l.chomp.split("\t", -1) }.select { |f| f.length == 3 && f[0] =~ /\A\d+\z/ }
abort "expected #{count} results, got #{results.length}:\n#{out[0, 2000]}" unless results.length == count

missed = []
refused = []
tally = Hash.new(0)
results.each do |i, state, deps|
  sql = queries[i.to_i]
  ours = begin
    a = Pgsqlarbiter.analyze(sql, schema: DATABASE)
    a.tables.map { |t| "table:#{t}" } + a.functions.map { |f| "function:#{f}" }
  rescue Pgsqlarbiter::Error => e
    e
  end

  # Resource exhaustion or an internal error would make the run meaningless.
  abort "server error #{state} on query #{i}; results are not trustworthy" if state.match?(/\A(53|54|57|58|XX)/)

  if state != "ok"
    tally[ours.is_a?(Exception) ? "both rejected" : "only PostgreSQL rejected"] += 1
  elsif ours.is_a?(Exception)
    tally["only pgsqlarbiter rejected"] += 1
    refused << [sql, "#{ours.class}: #{ours.message}"]
  else
    lost = deps.split - ours
    if lost.empty?
      tally["agreed"] += 1
    else
      tally["MISSED"] += 1
      missed << [sql, lost, deps]
    end
  end
end

puts "seed #{seed}, #{count} queries: " + tally.sort.map { |k, v| "#{v} #{k}" }.join(", ")
refused.first(15).each { |sql, why| puts "  refused valid SQL: #{sql.inspect}\n    #{why}" }
missed.first(30).each { |sql, lost, deps| puts "  MISSED #{lost.join(", ")} (PostgreSQL: #{deps}): #{sql.inspect}" }
abort "#{missed.length} missed reference(s), #{refused.length} valid quer(ies) refused" unless missed.empty? && refused.empty?
