# frozen_string_literal: true

# Fuzzes pgsqlarbiter's name resolution against a live PostgreSQL server.
#
#   rake test:postgres_fuzz_names           (connection from PG* variables)
#   ruby test/postgres/fuzz_names.rb COUNT SEED
#
# PostgreSQL treats "alias.name" as the function call name(alias) when alias has
# no column of that name. Here every name the generator uses is also a function
# that accepts anything, so whether a reference is a column or a call depends
# only on what the alias means and which columns it has: on scoping, shadowing,
# subquery result names, column alias lists, joins, CTEs and functions in FROM.
# For every query PostgreSQL accepts, its dependency records say which
# functions were really called and which table columns were really read, and
# pgsqlarbiter must have reported at least as much. Nothing is executed.
#
# A valid query that pgsqlarbiter refuses, or a column it reports as a possible
# call, is a false denial rather than a hole. Those are counted, and the run
# fails only if they become more common than the limits below.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "pgsqlarbiter"
require "open3"

count = (ARGV[0] || 5000).to_i
seed = (ARGV[1] || Random.new_seed % 1_000_000).to_i
RNG = Random.new(seed)
SCHEMA = "pgsqlarbiter_fuzz_names"
MAX_REFUSED = 0.05
MAX_OVER_REPORTED = 0.3

NAMES = %w[id name tags data user_id amount secret g n column1 column2 ordinality value key month total a b x users u
  generate_series unnest scalar_fn].freeze
ALIASES = %w[u o s x y t j g users orders].freeze
TABLES = %w[users orders secrets].freeze

def pick(list) = list[RNG.rand(list.length)]

# Most names in one query come from a few, so that references collide with
# labels, aliases and columns often enough to matter.
def column = (@hot && !chance(5)) ? pick(@hot) : pick(NAMES)

def chance(n) = RNG.rand(n) == 0

def expression(aliases)
  ref = "#{pick(aliases)}.#{column}"
  case RNG.rand(13)
  when 0 then "#{pick(aliases)}.*"
  when 1 then "#{ref} AS #{column}"
  when 2 then "(#{ref})"
  when 3 then "#{ref}::text"
  when 4 then "coalesce(#{ref}, NULL)"
  when 5 then "#{column}(#{ref})"
  when 6 then "(#{ref})::text AS #{column}"
  when 7 then "(SELECT #{ref})"
  when 8 then "#{SCHEMA}.#{pick(TABLES)}.#{column}"
  when 9 then chance(3) ? column : ref
  when 10 then pick(["#{ref} IS NULL", "- #{ref}", "#{ref} = #{ref}", "#{ref} + 1 AS #{column}", "(SELECT #{ref} AS #{column})"])
  else chance(3) ? "#{ref} AS #{column}" : ref
  end
end

def alias_list
  first = column
  chance(2) ? "(#{first})" : "(#{first}, #{pick(%w[b x key total] - [first])})"
end

def from_item(depth, outer, ctes)
  name = pick(ALIASES)
  case RNG.rand(depth > 2 ? 9 : 16)
  when 0
    table = pick(TABLES)
    [table, table]
  when 1, 2 then ["#{pick(TABLES)} #{name}", name]
  when 3 then ["#{pick(TABLES)} AS #{name}#{alias_list}", name]
  when 4
    function = pick(["generate_series(1, 2)", "unnest(ARRAY[1])", "report()", "pair()", "scalar_fn()", "single_out()",
      "jsonb_each('{}')", "json_array_elements('[]')", "unnest(ARRAY[1], ARRAY[2])", "now()", "current_date",
      "one_user()", "ROWS FROM (generate_series(1, 2), report())", "pg_catalog.generate_series(1, 2)",
      "#{SCHEMA}.report()"])
    function += " WITH ORDINALITY" if chance(4)
    case RNG.rand(4)
    when 0 then [function, function[/\A(?:[\w.]+\.)?(\w+)\(/, 1]]
    when 1 then ["#{function} AS #{name}#{alias_list}", name]
    else ["#{function} #{name}", name]
    end
  when 5 then ["(VALUES (1, 2)) #{name}#{alias_list if chance(2)}", name]
  when 6
    return from_item(depth, outer, ctes) if ctes.empty?

    cte = pick(ctes)
    chance(3) ? [cte, cte] : ["#{cte} #{name}#{alias_list if chance(4)}", name]
  when 7
    ["XMLTABLE('/r' PASSING ('<r/>'::xml) COLUMNS #{column} int PATH '.') #{name}", name]
  when 8
    ["JSON_TABLE('[]'::jsonb, '$[*]' COLUMNS (#{column} int, NESTED '$.q' COLUMNS (#{column} int))) #{name}", name]
  when 9, 10, 11
    lateral = chance(3) ? "LATERAL " : ""
    ["#{lateral}(#{select(depth + 1, outer, ctes)}) #{name}#{alias_list if chance(5)}", name]
  when 12, 13
    left, left_name = join_operand(depth, outer, ctes)
    right, right_name = join_operand(depth, outer, ctes)
    using = chance(3)
    join =
      case RNG.rand(6)
      when 0 then "#{left} NATURAL JOIN #{right}"
      when 1 then "#{left} CROSS JOIN #{right}"
      else "#{left} #{pick(["JOIN", "LEFT JOIN"])} #{right} #{using ? "USING (id)" : "ON #{on_condition([left_name, right_name], outer)}"}"
      end
    if using && join.end_with?(")") && chance(2)
      ["#{join} AS #{name}", [left_name, right_name, name]]
    else
      [join, [left_name, right_name]]
    end
  else
    left, = join_operand(depth, outer, ctes)
    right, = join_operand(depth, outer, ctes)
    ["(#{left} CROSS JOIN #{right}) AS #{name}#{alias_list if chance(4)}", name]
  end
end

# A join's ON condition sees the members of its join and the enclosing levels,
# but no other FROM item of its own level.
def on_condition(names, outer)
  return "true" if chance(2)

  aliases = (names.flatten.compact + outer).uniq
  aliases = ALIASES if aliases.empty? || chance(6)
  "#{pick(aliases)}.#{column} IS NOT NULL"
end

def join_operand(depth, outer, ctes)
  sql, name = from_item(depth + 1, outer, ctes)
  sql = "(#{sql})" if sql.match?(/ JOIN /) && !sql.start_with?("(")
  [sql, name]
end

def select(depth, outer, ctes)
  return "VALUES (1, 2)" if chance(25)
  return "TABLE #{pick(TABLES)}" if chance(40)

  items = Array.new(1 + RNG.rand(2)) { from_item(depth, outer, ctes) }
  aliases = (items.flat_map(&:last).compact + outer).uniq
  aliases << pick(ALIASES) if aliases.empty? || chance(12)
  targets = Array.new(1 + RNG.rand(3)) { chance(8) ? "*" : expression(aliases) }
  sql = "SELECT #{targets.join(", ")} FROM #{items.map(&:first).join(", ")}"
  conditions = []
  conditions << "#{pick(aliases)}.#{column} IS NOT NULL" if chance(4)
  conditions << "EXISTS (#{select(depth + 1, aliases, ctes)})" if depth < 3 && chance(5)
  sql += " WHERE #{conditions.join(" AND ")}" unless conditions.empty?
  sql += " GROUP BY #{column}" if chance(30)
  sql += " UNION ALL #{select(depth + 1, outer, ctes)}" if depth < 3 && chance(12)
  sql += " ORDER BY #{chance(2) ? column : "#{pick(aliases)}.#{column}"}" if chance(6) && !sql.include?(" UNION ")
  sql
end

# Shapes where the meaning of "alias.name" turns on one renaming rule. Each
# name comes from a pool of three, so the reference lands on a renamed, hidden
# or surviving column about as often as not.
COLUMNS_OF = {"users" => %w[id name tags data], "orders" => %w[id user_id amount], "secrets" => %w[id secret]}.freeze
SCALAR_FUNCTIONS = ["generate_series(1, 2)", "unnest(ARRAY[1])", "scalar_fn()", "pg_catalog.generate_series(1, 2)"].freeze

def focused
  table = pick(TABLES)
  other = pick(TABLES)
  pool = (COLUMNS_OF[table].sample(2, random: RNG) + [pick(NAMES)]).uniq
  n = -> { pick(pool) }
  list = chance(2) ? "(#{n.call})" : "(#{pool.sample(2, random: RNG).join(", ")})"
  list = "" if chance(4)
  value = lambda do
    column = "t.#{pick(COLUMNS_OF[table])}"
    case RNG.rand(6)
    when 0, 1 then column
    when 2 then "#{column} IS NULL"
    when 3 then pick(["- t.id", "t.id + 1", "(#{column})", "#{column}::text", "(SELECT #{column})"])
    else "#{n.call}(#{column})#{" AS #{n.call}" if chance(2)}"
    end
  end
  case RNG.rand(10)
  when 0 then "WITH c#{list} AS (SELECT #{value.call} FROM #{table} t) SELECT c.#{n.call} FROM c"
  when 1 then "WITH c#{list} AS (SELECT #{value.call}, t.id AS #{n.call} FROM #{table} t) SELECT z.#{n.call}, z.#{n.call} AS q FROM c z"
  when 2 then "SELECT x.#{n.call} FROM (SELECT * FROM (#{table} t CROSS JOIN #{pick(SCALAR_FUNCTIONS)} f) AS j#{list}) x"
  when 3 then "SELECT j.#{n.call} FROM (#{table} t CROSS JOIN #{other} o) AS j#{list}"
  when 4
    function = pick(SCALAR_FUNCTIONS)
    label = chance(3) ? "" : " #{pick(%w[g f]) }"
    known = label.empty? ? function[/(\w+)\(/, 1] : label.strip
    reference = pick([known, function[/(\w+)\(/, 1], "g", "f"])
    "SELECT #{known}.#{reference} FROM #{function}#{label}"
  when 5
    "SELECT x.#{n.call} FROM (SELECT #{n.call}(t.id) AS #{n.call} FROM #{table} t UNION ALL " \
      "SELECT #{n.call}(t.id) AS #{n.call} FROM #{table} t) x"
  when 6 then "SELECT j.#{pick(pool + ["id"])} FROM #{table} t JOIN #{other} o USING (id) AS j"
  when 7 then "SELECT x.#{n.call} FROM (SELECT #{value.call}, #{value.call} AS q2 FROM #{table} t) x#{list}"
  when 8
    # In a join's ON condition, t names the inner t only if that is a member
    # of the join and not hidden by an inner join alias; otherwise the outer t.
    third = pick(TABLES)
    inner = pick(["#{other} t JOIN #{third} o", "#{third} o JOIN #{other} t", "#{other} t, #{third} p JOIN #{third} o",
      "(#{other} t JOIN #{third} p ON true) j JOIN #{third} o", "#{third} o JOIN (#{other} t JOIN #{third} p ON true)",
      "#{third} o JOIN #{third} p ON true JOIN #{other} t", "(#{third} t JOIN #{third} p ON true) j JOIN #{other} t",
      "(#{other} t JOIN #{third} p ON true) t JOIN #{third} o", "#{other} t JOIN #{third} p USING (id) AS j JOIN #{third} o"])
    name = pick(COLUMNS_OF[other] + COLUMNS_OF[table] + [pick(NAMES)])
    condition = chance(3) ? "EXISTS (SELECT t.#{name})" : "t.#{name} IS NOT NULL"
    subquery = "SELECT 1 FROM #{inner} ON #{condition}"
    if chance(2)
      "SELECT 1 FROM #{table} t WHERE EXISTS (#{subquery})"
    else
      "SELECT 1 FROM #{table} t LEFT JOIN LATERAL (#{subquery}) x ON true"
    end
  else "SELECT t.#{n.call} FROM #{table} AS t#{list}"
  end
end

def query
  return focused if chance(4)

  @hot = NAMES.sample(4, random: RNG)
  ctes = []
  definitions = []
  if chance(4)
    (1 + RNG.rand(2)).times do
      name = pick(%w[c1 c2 users u x])
      definitions << "#{name}#{alias_list if chance(4)} AS (#{select(1, [], ctes)})"
      ctes << name
    end
  end
  body = select(0, [], ctes)
  definitions.empty? ? body : "WITH #{"RECURSIVE " if chance(5)}#{definitions.join(", ")} #{body}"
end

queries = Array.new(count) { query }

script = +<<~SQL
  \\set ON_ERROR_STOP 1
  SET client_min_messages = warning;
  DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE;
  CREATE SCHEMA #{SCHEMA};
  SET search_path = #{SCHEMA};
  CREATE TABLE users(id int, name text, tags text[], data jsonb);
  CREATE TABLE secrets(id int, secret text);
  CREATE TABLE orders(id int, user_id int, amount numeric);
  CREATE FUNCTION report() RETURNS TABLE(month int, total int) LANGUAGE sql AS 'select 1, 2';
  CREATE FUNCTION pair(OUT a int, OUT b text) LANGUAGE sql AS $$select 1, 'x'$$;
  CREATE FUNCTION scalar_fn() RETURNS int LANGUAGE sql AS 'select 1';
  CREATE FUNCTION single_out(OUT value int) LANGUAGE sql AS 'select 1';
  CREATE TYPE person AS (id int, name text, tags text[]);
  CREATE FUNCTION one_user() RETURNS person LANGUAGE sql AS 'select id, name, tags from users limit 1';
SQL
NAMES.each do |name|
  script << "CREATE FUNCTION #{name}(anyelement) RETURNS int LANGUAGE sql AS 'select 1';\n"
end
script << <<~SQL
  \\o /dev/null
  \\o
  SELECT 'schema', 0, (#{Pgsqlarbiter::Schema::QUERY.strip});
  CREATE TEMP TABLE fuzz_query(i int, hex text);
  CREATE TEMP TABLE fuzz_result(i int, state text, deps text);
  COPY fuzz_query FROM stdin;
SQL
queries.each_with_index { |q, i| script << "#{i}\t#{q.unpack1("H*")}\n" }
script << "\\.\n"
BATCH = 250
(0...count).step(BATCH) do |from|
  script << format(<<~'SQL', from: from, to: from + BATCH)
    DO $fuzz$
    DECLARE q record; found text;
    BEGIN
      FOR q IN SELECT * FROM fuzz_query WHERE i >= %{from} AND i < %{to} ORDER BY i LOOP
        BEGIN
          EXECUTE 'CREATE TEMP VIEW fuzz_view AS SELECT 1 AS one FROM (' || convert_from(decode(q.hex, 'hex'), 'UTF8') || E'\n) fuzz_outer';
          SELECT coalesce(string_agg(DISTINCT CASE
                   WHEN d.refclassid = 'pg_class'::regclass AND d.refobjsubid > 0 THEN
                     'column:' || (SELECT relname FROM pg_class WHERE oid = d.refobjid) || '.' ||
                     (SELECT attname FROM pg_attribute WHERE attrelid = d.refobjid AND attnum = d.refobjsubid)
                   WHEN d.refclassid = 'pg_class'::regclass THEN 'table:' || (SELECT relname FROM pg_class WHERE oid = d.refobjid)
                   WHEN d.refclassid = 'pg_proc'::regclass THEN 'function:' || (SELECT proname FROM pg_proc WHERE oid = d.refobjid)
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
  SELECT 'result', i, state || ' ' || deps FROM fuzz_result ORDER BY i;
  DROP SCHEMA #{SCHEMA} CASCADE;
SQL

out, status = Open3.capture2e("psql", "-X", "-q", "-A", "-t", "-F", "\t", "-f", "-", stdin_data: script)
abort "psql failed (is PostgreSQL reachable through PG* variables?):\n#{out[0, 2000]}" unless status.success?

rows = out.lines.map { |l| l.chomp.split("\t", 3) }.select { |f| f.length == 3 }
document = rows.find { |kind, _, _| kind == "schema" }&.last
abort "no schema document in the output:\n#{out[0, 2000]}" unless document
schema = Pgsqlarbiter::Schema.load(document)
results = rows.select { |kind, _, _| kind == "result" }
abort "expected #{count} results, got #{results.length}:\n#{out[0, 2000]}" unless results.length == count

missed = []
refused = Hash.new { |h, k| h[k] = [] }
tally = Hash.new(0)
states = Hash.new(0)
over_reported = 0
results.each do |_, i, outcome|
  state, *deps = outcome.split
  sql = queries[i.to_i]
  # Resource exhaustion would make the run meaningless. An internal error
  # (XX000) on one query is only that query being rejected.
  abort "server error #{state} on query #{i}; results are not trustworthy:\n#{sql}" if state.match?(/\A(53|54|57|58)/)

  analysis = begin
    Pgsqlarbiter.analyze(sql, schema: schema)
  rescue Pgsqlarbiter::Error => e
    e
  end

  if state != "ok"
    tally[analysis.is_a?(Exception) ? "both rejected" : "only PostgreSQL rejected"] += 1
    states[state] += 1
    puts "  #{state}: #{sql}" if ENV["SHOW"] == state && states[state] <= 6
  elsif analysis.is_a?(Exception)
    tally["only pgsqlarbiter rejected"] += 1
    refused[analysis.message.sub(/"[^"]*"/, '"…"')] << sql
  else
    functions = analysis.functions.map { |f| "function:#{f.split(".").last}" }
    columns = analysis.columns.map do |c|
      table, _, field = c.rpartition(".")
      "column:#{table.split(".").last}.#{field}"
    end
    lost = deps.reject do |dependency|
      case dependency
      when /\Afunction:/ then functions.include?(dependency)
      when /\Acolumn:(.*)\.[^.]*\z/
        # Fields of a composite type are not columns of a table.
        !TABLES.include?($1) || columns.include?(dependency) || columns.include?("column:#{$1}.*")
      else true
      end
    end
    if lost.empty?
      tally["agreed"] += 1
      extra = functions & NAMES.map { |n| "function:#{n}" } - deps
      over_reported += 1 unless extra.empty?
      puts "  over-reported #{extra.join(", ")}: #{sql}" if ENV["VERBOSE"] && !extra.empty? && over_reported <= 14
    else
      tally["MISSED"] += 1
      missed << [sql, lost, deps]
    end
  end
end

valid = tally["agreed"] + tally["MISSED"] + tally["only pgsqlarbiter rejected"]
puts "seed #{seed}, #{count} queries: " + tally.sort.map { |k, v| "#{v} #{k}" }.join(", ") +
  "; #{over_reported} agreed with a column reported as a possible call"
puts "  PostgreSQL's rejections by SQLSTATE: #{states.sort_by { |_, n| -n }.first(6).map { |k, v| "#{k} x#{v}" }.join(", ")}" if ENV["VERBOSE"]
refused.sort_by { |_, list| -list.length }.first(8).each do |reason, list|
  puts "  refused #{list.length}: #{reason}\n    e.g. #{list.first}"
end
missed.first(30).each { |sql, lost, deps| puts "  MISSED #{lost.join(", ")} (PostgreSQL: #{deps.join(" ")}):\n    #{sql}" }
abort "#{missed.length} missed reference(s)" unless missed.empty?
abort "too few valid queries (#{valid}) for the run to mean anything" if valid < count / 20
if tally["only pgsqlarbiter rejected"] > valid * MAX_REFUSED || over_reported > valid * MAX_OVER_REPORTED
  abort "false denials are more common than expected"
end
