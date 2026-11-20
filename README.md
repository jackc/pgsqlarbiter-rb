# pgsqlarbiter

[![CI](https://github.com/jackc/pgsqlarbiter-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/jackc/pgsqlarbiter-rb/actions/workflows/ci.yml)

pgsqlarbiter is SQL query permission system for PostgreSQL. It is designed for granting semi-trusted users access to a PostgreSQL database. PostgreSQL's permission system is a necessary foundation, but further restrictions are often required. pgsqlarbiter adds the following:

* Only single statement DML (SELECT, INSERT, UPDATE, DELETE, MERGE, or VALUES) queries are allowed.
* All referenced tables, views, named functions, and named types must be whitelisted.
* Optionally, only whitelisted columns of a table may be used.

Queries are tokenized by a port of PostgreSQL's own scanner and parsed with PostgreSQL's own grammar
rules, so pgsqlarbiter reads a query the way the server will. Names are then resolved against a
description of your tables and columns that you supply. Anything it does not recognize is refused.

These additional restrictions close gaps that are difficult or impossible to address with the PostgreSQL permission system alone, such as:

* Exposure of system information via `information_schema` or `pg_catalog`.
* Exposure of system information via `SHOW`.
* Transactions that can block other users.
* `SET` can disable restrictions such as `statement_timeout`.
* Unexpected access to dangerous built-in functions like `set_config`, `pg_sleep`, `lo_*`, `pg_advisory_lock`, and `pg_notify`.
* Catalog lookups through casts such as `'pg_authid'::regclass`.


## Installation

Add to your Gemfile:

```ruby
gem "pgsqlarbiter"
```

Or install directly:

```
gem install pgsqlarbiter
```

## Usage

### Describing the database with a `Schema`

Every check needs a `Pgsqlarbiter::Schema`: the tables and views that exist and all of their columns.
PostgreSQL treats `x.name` as the function call `name(x)` when `x` has no column called `name`, so
pgsqlarbiter has to know the columns to tell a column from a hidden function call.

```ruby
require "pgsqlarbiter"

schema = Pgsqlarbiter::Schema.new({
  "users" => %w[id name email active password_hash],
  "orders" => %w[id user_id total],
  "order_items" => %w[id order_id quantity],
  "logs" => %w[id message],
  "events" => %w[id name],
  "people" => %w[id current_mood]
})
```

A schema describes the database; it allows nothing by itself. List every column of each table,
including ones no query may use. A table that is not in the schema is always denied.

You can build the schema from the database instead of writing it out. `Pgsqlarbiter::Schema::QUERY` is
a catalog query that returns one JSON document, and `Schema.load` reads it. pgsqlarbiter itself never
connects to a database, so run the query with your own driver, as the role and `search_path` your
restricted queries use:

```ruby
json = connection.exec(Pgsqlarbiter::Schema::QUERY).getvalue(0, 0)  # with the pg gem
schema = Pgsqlarbiter::Schema.load(json)
```

Each table is listed as `schema.table`, and also as plain `table` when the `search_path` finds it that
way. Reload the schema whenever the database changes, for example after running migrations.

The schema also says which columns a function returns when it is used in `FROM`, for PostgreSQL's own
functions as well as yours. `Schema::QUERY` works this out from the catalog. In a hand-written schema
you declare the ones your queries need:

```ruby
schema = Pgsqlarbiter::Schema.new(
  {"users" => %w[id name]},
  functions: {
    "monthly_report" => %w[month total],  # returns these columns
    "generate_series" => :scalar,         # returns one value, named after its alias
    "jsonb_each" => %w[key value]
  }
)
```

pgsqlarbiter assumes nothing about a function the schema does not describe. Such a function can still
be used in `FROM`, and `SELECT g FROM generate_series(1, 3) g` or `... AS g(n)` work either way, but
`g.g` is then treated as a possible function call.

A name stands for every function a call of it can reach, because PostgreSQL chooses among the functions
of one name by the arguments of each call. Declare columns for a name only when all of those functions
return the same columns. `unnest` is the usual trap: `unnest(anyarray)` returns whatever the array
holds and `unnest(tsvector)` returns three columns, so `Schema::QUERY` leaves it out, and its columns
must be named with a column alias list: `FROM unnest($1) AS t(v)`.

### Quick check with `Pgsqlarbiter.allow?`

The simplest way to check whether a query is permitted:

```ruby
sql = "SELECT id, name FROM users WHERE active = $1"

Pgsqlarbiter.allow?(sql, schema: schema, allowed_tables: ["users"])
# => true

Pgsqlarbiter.allow?(sql, schema: schema, allowed_tables: ["orders"])
# => false (references table "users" which is not in the whitelist)
```

By default only `SELECT` statements are allowed. Pass `allowed_statement_types:` to allow other DML:

```ruby
sql = "INSERT INTO logs (message) VALUES ($1)"

Pgsqlarbiter.allow?(sql, schema: schema, allowed_tables: ["logs"], allowed_statement_types: [:select, :insert])
# => true
```

### Reusable arbiter with `Pgsqlarbiter::Arbiter`

When checking many queries against the same rules, create an `Arbiter` once and reuse it:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  schema: schema,
  allowed_statement_types: [:select, :insert, :update, :delete],
  allowed_tables: ["users", "orders", "order_items"]
)

arbiter.allow?("SELECT * FROM users")                # => true
arbiter.allow?("DELETE FROM orders WHERE id = $1")    # => true
arbiter.allow?("DROP TABLE users")                    # raises DisallowedStatementError
arbiter.allow?("SELECT * FROM pg_catalog.pg_tables")  # => false
```

Creating an arbiter raises `ArgumentError` if a whitelisted table or column is not in the schema.

### Column restrictions

Pass a Hash as `allowed_tables` to limit which columns of a table may be used. Each value is `:all` or
a list of column names:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  schema: schema,
  allowed_statement_types: [:select, :update],
  allowed_tables: {"users" => %w[id name email], "orders" => :all}
)

arbiter.allow?("SELECT id, name FROM users WHERE email = $1")       # => true
arbiter.allow?("SELECT password_hash FROM users")                   # => false
arbiter.allow?("SELECT id FROM users WHERE password_hash LIKE $1")  # => false
arbiter.allow?("UPDATE users SET password_hash = $1")               # => false
arbiter.allow?("SELECT * FROM orders")                              # => true
arbiter.allow?("SELECT * FROM users")                               # => false

arbiter.judge("SELECT u.name, u.password_hash FROM users u").disallowed_columns
# => ["users.password_hash"]
```

A column counts wherever the query uses it: in the select list, in `WHERE`, `ORDER BY` or a join
condition, inside a subquery, as the target of `SET` or an `INSERT` column list, or in `RETURNING`.
There is one list per table for reading and writing alike.

A table with a column list cannot be used in a way that takes all of its columns at once: `*`, a
whole-row reference such as `to_jsonb(u)`, `TABLE users`, `NATURAL JOIN`, an `INSERT` without a column
list, or a column alias list (`users AS u(a, b)`). Queries on such a table must name the columns they
use. These show up as `"users.*"` in `disallowed_columns`. This rule keeps a column that was added to
the database but not yet to the schema from leaking through `SELECT *`.

PostgreSQL's own column privileges (`GRANT SELECT (id, name) ON users`) remain the authoritative
enforcement; this is a second layer in front of them.

### Detailed denial reasons with `judge`

When you need to know *why* a query was denied, use `judge` instead of `allow?`. It returns a
`Verdict` with the specific checks that failed:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  schema: schema,
  allowed_statement_types: [:select],
  allowed_tables: ["users"],
  allowed_functions: ["count"]
)

verdict = arbiter.judge("INSERT INTO orders SELECT count(*), pg_sleep(1), 'x'::regclass FROM secrets")
verdict.allowed?                   # => false
verdict.statement_type             # => :insert
verdict.statement_type_allowed?    # => false
verdict.disallowed_statement_types # => [:insert]
verdict.disallowed_tables          # => ["orders", "secrets"]
verdict.disallowed_columns         # => []
verdict.disallowed_functions       # => ["pg_sleep"]
verdict.disallowed_types           # => ["regclass"]
verdict.reasons
# => ["statement type :insert is not allowed",
#     "table \"orders\" is not allowed",
#     "table \"secrets\" is not allowed",
#     "function \"pg_sleep\" is not allowed",
#     "type \"regclass\" is not allowed"]
```

A one-off convenience method is also available:

```ruby
verdict = Pgsqlarbiter.judge("SELECT * FROM secrets", schema: schema, allowed_tables: ["users"])
verdict.allowed?           # => false
verdict.disallowed_tables  # => ["secrets"]
```

### Analyzing queries with `Pgsqlarbiter.analyze`

Use `analyze` to inspect a query without checking permissions:

```ruby
result = Pgsqlarbiter.analyze(
  "SELECT u.name, count(o.id) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.name",
  schema: schema
)

result.statement_type   # => :select
result.statement_types  # => [:select]
result.tables           # => ["orders", "users"]
result.columns          # => ["orders.id", "orders.user_id", "users.id", "users.name"]
result.functions        # => ["count"]
result.types            # => []
```

`columns` lists `table.*` when a query uses every column of a table at once. `analyze` reports what a
query uses and judges nothing: for a table that is missing from the schema it cannot tell columns from
function calls, so its `columns` and `functions` are only reliable when every table in `tables` is in
the schema. `Arbiter` always denies a table that is not.

### Statement types a query needs

A query can need more than the type of its outermost statement. `statement_types` lists everything
that must be allowed:

```ruby
Pgsqlarbiter.analyze("WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone", schema: schema).statement_types
# => [:delete, :select]

Pgsqlarbiter.analyze("SELECT * FROM users FOR UPDATE", schema: schema).statement_types
# => [:select, :update]   (row locks need UPDATE privilege)

Pgsqlarbiter.analyze("INSERT INTO users VALUES (1) ON CONFLICT (id) DO UPDATE SET name = 'x'", schema: schema).statement_types
# => [:insert, :update]
```

`SELECT ... INTO` creates a table and is always refused. `:merge` covers whatever a `MERGE` statement's
`WHEN` clauses do.

### Custom function whitelists

By default, `DEFAULT_QUERY_FUNCTIONS` (a curated set of common PostgreSQL functions) is used.
You can provide your own:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  schema: schema,
  allowed_statement_types: [:select],
  allowed_tables: ["events"],
  allowed_functions: Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS | Set["my_custom_func"]
)

arbiter.allow?("SELECT my_custom_func(id) FROM events")  # => true
```

Or restrict to a minimal set:

```ruby
Pgsqlarbiter.allow?(
  "SELECT count(*) FROM users",
  schema: schema,
  allowed_tables: ["users"],
  allowed_functions: ["count"]
)
# => true
```

Everything that calls a function counts, however it is written: `coalesce(...)`, `extract(... FROM ...)`,
and the parenthesis-less `current_user`, `session_user` and `current_schema` are all function names.
When adding to the list, do not add a function that executes SQL passed to it as text or looks up an
object by a name passed as text (`ts_rewrite`, `query_to_xml`, `set_config`, ...).

### Type whitelists

Types named in a cast (`x::type`, `CAST(x AS type)`), a typed literal (`type 'text'`) or a column
definition list must be in `allowed_types`. The default, `DEFAULT_QUERY_TYPES`, covers the ordinary
data types and leaves out the object identifier types (`regclass`, `regproc`, ...), which look up
catalog objects by name.

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  schema: schema,
  allowed_statement_types: [:select],
  allowed_tables: ["people"],
  allowed_types: Pgsqlarbiter::DEFAULT_QUERY_TYPES | ["mood"]
)

arbiter.allow?("SELECT current_mood::mood FROM people")  # => true
arbiter.allow?("SELECT 'people'::regclass")              # => false
```

Types spelled with SQL keywords are recorded under one name whatever the spelling: `int` and `integer`
are `"integer"`, `varchar(20)` and `character varying` are `"character varying"`, `decimal` is
`"numeric"`, `timestamp without time zone` is `"timestamp"`. Any other type is recorded as written
(`int4`, `timestamptz`, `myschema.mood`). An array type is recorded as its element type.

### Error handling

Pgsqlarbiter raises specific exceptions for different failure modes:

```ruby
begin
  Pgsqlarbiter.analyze("DROP TABLE users", schema: schema)
rescue Pgsqlarbiter::DisallowedStatementError => e
  # Statement type (DDL, DCL, etc.) is not allowed
  e.message  # => "DROP statements are not allowed"
end

begin
  Pgsqlarbiter.analyze("SELECT 1; DELETE FROM users", schema: schema)
rescue Pgsqlarbiter::MultipleStatementsError => e
  # Multiple statements in a single query
  e.message  # => "multiple statements are not allowed"
end

begin
  Pgsqlarbiter.analyze("SELECT nickname FROM users", schema: schema)
rescue Pgsqlarbiter::UnresolvedNameError => e
  # A column or alias that is not in the schema or the query's FROM clause
  e.message  # => "column \"nickname\" cannot be resolved"
end
```

All exceptions inherit from `Pgsqlarbiter::Error`:

| Exception | Raised when |
|---|---|
| `LexError` | The SQL cannot be tokenized (unexpected characters, unterminated strings, invalid UTF-8) |
| `ParseError` | The SQL is empty, is not valid syntax, or uses syntax pgsqlarbiter refuses |
| `UnresolvedNameError` | A column or table alias cannot be matched to the schema and the query's `FROM` clause |
| `MultipleStatementsError` | More than one statement in the SQL |
| `DisallowedStatementError` | Statement type is not SELECT, INSERT, UPDATE, DELETE, MERGE, or VALUES |

Treat any `Pgsqlarbiter::Error` as a denial.

### Supported statement types

| Symbol | SQL |
|---|---|
| `:select` | `SELECT` (including `WITH ... SELECT`, `TABLE name`, and parenthesized selects) |
| `:insert` | `INSERT` (including `WITH ... INSERT`) |
| `:update` | `UPDATE` (including `WITH ... UPDATE`) |
| `:delete` | `DELETE` (including `WITH ... DELETE`) |
| `:merge` | `MERGE` (including `WITH ... MERGE`) |
| `:values` | `VALUES` |

## How it works

1. **Lexing.** `Pgsqlarbiter::Lexer` is a rule-for-rule port of PostgreSQL's scanner (`scan.l`) and of
   the token filter in `parser.c`. Token boundaries are where any disagreement with the server would
   let SQL hide, so this is tested against a live server (see below).
2. **Parsing.** `Pgsqlarbiter::Parser` is generated from PostgreSQL's grammar (`gram.y`). A script keeps
   every production reachable from SELECT, INSERT, UPDATE, DELETE and MERGE, unchanged and with
   PostgreSQL's precedence declarations, and builds an LALR parser from them. Syntax PostgreSQL would
   reject is rejected here.
3. **Analysis.** `Pgsqlarbiter::Analyzer` walks the syntax tree. Each place the grammar allows a table,
   function or type name has an explicit handler; a name reached any other way raises an error instead
   of being ignored. `WITH` names follow PostgreSQL's scoping rules and never hide a function, a
   qualified name, or the target of a write.

4. **Name resolution.** Every column reference is resolved against the `Schema` and the query's own
   `FROM` clauses, subqueries, `WITH` queries, joins and aliases. `alias.name` counts as a column only
   when `name` is certainly a column of everything `alias` could refer to; otherwise it counts as a
   call of the function `name`. An unqualified name is charged to every table in scope that has a
   column of that name. A name that cannot be found is refused.

pgsqlarbiter is pure Ruby with no runtime dependencies and never connects to a database.

## Limitations

pgsqlarbiter is not sufficient security on its own. It is designed to be an additional layer on top of using a heavily restricted PostgreSQL user.

* **Server settings are assumed.** `standard_conforming_strings` must be `on` (the default since
  PostgreSQL 9.1) and the client and server encodings must be UTF-8. With other settings the server can
  tokenize a query differently from pgsqlarbiter.
* **Send exactly the string you checked, and prefer the extended query protocol.** The server refuses
  multiple statements in an extended-protocol query, which backs up pgsqlarbiter's own check.
* **Operators pass through without filtering.** An operator is implemented by a function, and
  user-defined operators can be used. The explicit `OPERATOR(schema.op)` syntax is refused.
* **Implicit conversions pass through.** Only types that are named in the query are checked.
* **The schema must match the database.** A column that is missing from the schema is denied, which is
  safe. A column that is still listed after it was dropped is treated as a column, while PostgreSQL
  would look for a function of that name; reload the schema whenever the database changes. Build it
  with the `search_path` the restricted role uses, because that decides what an unqualified name means.
  The columns declared for a function are a promise about every function of that name, yours and
  PostgreSQL's own; pgsqlarbiter cannot check a hand-written declaration, so prefer `Schema::QUERY`.
* **Some valid queries are denied.** These are the cases where pgsqlarbiter cannot be certain what a
  name means, and each has a spelling that works:
  * `(expr).name` always counts as a call of `name`, so reading a field of a composite value that way
    needs `name` in the function whitelist.
  * A column of a function in `FROM` that the schema does not describe, such as `unnest`, must be named
    through a column alias list: `FROM f(...) AS alias(column, ...)`.
  * A result column of a subquery is known by name only when it has an `AS` label or is a plain column
    or function call. Give other expressions a label to refer to them from outside:
    `(SELECT a + b AS total ...) x`.
  * A column alias list hides the columns it does not rename: after `FROM users AS u(uid)`, only
    `u.uid` is known.
  * When the same alias is used at two nesting levels of one query, `alias.name` means the nearest
    one, as in PostgreSQL, except where PostgreSQL may skip that level's `FROM` items: inside a `FROM`
    clause (a join's `ON` condition, a `LATERAL` or other subquery in `FROM`, a function's arguments),
    for a table inside a join that has an alias, and for a schema-qualified name like `public.users.id`.
    There `alias.name` must be a column of every item the alias names, at that level and every
    enclosing one. Distinct aliases avoid this.
  * Unquoted identifiers containing non-ASCII upper-case letters are refused because PostgreSQL folds
    them differently depending on the server encoding; quote them.
  * A query on which name resolution would take an unreasonable amount of work, such as thousands of
    `FROM` items sharing one alias, is refused.
* Names are recorded exactly as written, after PostgreSQL's case folding. Schema-qualified references
  like `public.users` are distinct from `users`, and what an unqualified name means depends on the
  role's `search_path`. The schema and the whitelists must include the exact form used in queries.
* Quoted identifiers containing dots are rejected where a table, function or type name is expected.
  Columns whose names contain a dot, or are `*`, cannot be listed in a schema, so queries that use
  them are denied.
* The grammar is PostgreSQL 18's. Syntax added by a later release is denied until the parser is
  regenerated.

## Development

```
bundle exec rake test                       # unit tests, no database needed
bundle exec rake test:postgres              # compare analysis with a live server's dependency records
bundle exec rake test:postgres_fuzz         # fuzz the lexer against a live server
bundle exec rake test:postgres_fuzz_names   # fuzz name resolution against a live server
```

The three live tests use the usual `PG*` environment variables. They create and drop schemas named
`pgsqlarbiter_oracle`, `pgsqlarbiter_fuzz` and `pgsqlarbiter_fuzz_names` and execute none of the queries
they check. Each compares what pgsqlarbiter reports with the functions, tables and columns PostgreSQL
records as dependencies of the same query. The first also checks `Schema::QUERY` against the columns
the server really gives each function in `FROM`.

`lib/pgsqlarbiter/parser.rb` and `lib/pgsqlarbiter/keywords.rb` are generated. To move to another
PostgreSQL release, change `POSTGRESQL_TAG` in the `Rakefile`, then:

```
bundle exec rake grammar:fetch grammar:generate
```

Review the diff of `grammar/pg_dml.y`, which is the extracted grammar, and run all four test tasks.
`test/pgsqlarbiter/test_grammar.rb` fails if the new grammar has a place for a table, function or type
name that the analyzer does not handle. The hand-written lexer has to be compared with the new
release's `scan.l` by hand.

## License

pgsqlarbiter is released under the MIT license. The generated parser and keyword table are derived
from PostgreSQL and carry the PostgreSQL License, and the parser embeds racc's runtime under racc's
terms; both notices are in the generated files.

## Other Implementations

* [pgsqlarbiter-go](https://github.com/jackc/pgsqlarbiter-go) - Go
