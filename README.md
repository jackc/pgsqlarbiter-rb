# pgsqlarbiter

pgsqlarbiter is SQL query permission system for PostgreSQL. It is designed for granting semi-trusted users access to a PostgreSQL database. PostgreSQL's permission system is a necessary foundation, but further restrictions are often required. pgsqlarbiter adds the following:

* Only single statement DML (SELECT, INSERT, UPDATE, DELETE, MERGE, or VALUES) queries are allowed.
* All referenced tables, views, and named functions must be whitelisted.

These additional restrictions close gaps that are difficult or impossible to address with the PostgreSQL permission system alone, such as:

* Exposure of system information via `information_schema` or `pg_catalog`.
* Exposure of system information via `SHOW`.
* Transactions that can block other users.
* `SET` can disable restrictions such as `statement_timeout`.
* Unexpected access to dangerous built-in functions like `set_config`, `pg_sleep`, `lo_*`, `pg_advisory_lock`, and `pg_notify`.


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

### Quick check with `Pgsqlarbiter.allow?`

The simplest way to check whether a query is permitted:

```ruby
require "pgsqlarbiter"

sql = "SELECT id, name FROM users WHERE active = $1"

Pgsqlarbiter.allow?(sql, tables: ["users"])
# => true

Pgsqlarbiter.allow?(sql, tables: ["orders"])
# => false (references table "users" which is not in the whitelist)
```

By default only `SELECT` statements are allowed. Pass `statement_types:` to allow other DML:

```ruby
sql = "INSERT INTO logs (message) VALUES ($1)"

Pgsqlarbiter.allow?(sql, tables: ["logs"], statement_types: [:select, :insert])
# => true
```

### Reusable arbiter with `Pgsqlarbiter::Arbiter`

When checking many queries against the same rules, create an `Arbiter` once and reuse it:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  statement_types: [:select, :insert, :update, :delete],
  tables: ["users", "orders", "order_items"]
)

arbiter.allow?("SELECT * FROM users")                # => true
arbiter.allow?("DELETE FROM orders WHERE id = $1")    # => true
arbiter.allow?("DROP TABLE users")                    # raises DisallowedStatementError
arbiter.allow?("SELECT * FROM pg_catalog.pg_tables")  # => false
```

### Detailed denial reasons with `judge`

When you need to know *why* a query was denied, use `judge` instead of `allow?`. It returns a
`Verdict` with the specific checks that failed:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  statement_types: [:select],
  tables: ["users"],
  functions: ["count"]
)

verdict = arbiter.judge("INSERT INTO orders SELECT count(*), pg_sleep(1) FROM secrets")
verdict.allowed?                # => false
verdict.statement_type          # => :insert
verdict.statement_type_allowed? # => false
verdict.disallowed_tables       # => ["orders", "secrets"]
verdict.disallowed_functions    # => ["pg_sleep"]
verdict.reasons
# => ["statement type :insert is not allowed",
#     "table \"orders\" is not allowed",
#     "table \"secrets\" is not allowed",
#     "function \"pg_sleep\" is not allowed"]
```

A one-off convenience method is also available:

```ruby
verdict = Pgsqlarbiter.judge("SELECT * FROM secrets", tables: ["users"])
verdict.allowed?           # => false
verdict.disallowed_tables  # => ["secrets"]
```

### Analyzing queries with `Pgsqlarbiter.analyze`

Use `analyze` to inspect a query without checking permissions:

```ruby
result = Pgsqlarbiter.analyze(
  "SELECT u.name, count(o.id) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.name"
)

result.statement_type  # => :select
result.tables          # => ["orders", "users"]
result.functions       # => ["count"]
```

### Custom function whitelists

By default, `DEFAULT_QUERY_FUNCTIONS` (a curated set of ~180 common PostgreSQL functions) is used.
You can provide your own:

```ruby
arbiter = Pgsqlarbiter::Arbiter.new(
  statement_types: [:select],
  tables: ["events"],
  functions: Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS | Set["my_custom_func"]
)

arbiter.allow?("SELECT my_custom_func(id) FROM events")  # => true
```

Or restrict to a minimal set:

```ruby
Pgsqlarbiter.allow?(
  "SELECT count(*) FROM users",
  tables: ["users"],
  functions: ["count"]
)
# => true
```

### Error handling

Pgsqlarbiter raises specific exceptions for different failure modes:

```ruby
begin
  Pgsqlarbiter.analyze("DROP TABLE users")
rescue Pgsqlarbiter::DisallowedStatementError => e
  # Statement type (DDL, DCL, etc.) is not allowed
  e.message  # => "DROP statements are not allowed"
end

begin
  Pgsqlarbiter.analyze("SELECT 1; DELETE FROM users")
rescue Pgsqlarbiter::MultipleStatementsError => e
  # Multiple statements in a single query
  e.message  # => "multiple statements are not allowed"
end
```

All exceptions inherit from `Pgsqlarbiter::Error`:

| Exception | Raised when |
|---|---|
| `LexError` | Invalid syntax (unexpected characters, unterminated strings) |
| `ParseError` | Unparseable SQL structure or empty query |
| `MultipleStatementsError` | More than one statement in the SQL |
| `DisallowedStatementError` | Statement type is not SELECT, INSERT, UPDATE, DELETE, MERGE, or VALUES |

### Supported statement types

| Symbol | SQL |
|---|---|
| `:select` | `SELECT` (including `WITH ... SELECT`) |
| `:insert` | `INSERT` (including `WITH ... INSERT`) |
| `:update` | `UPDATE` (including `WITH ... UPDATE`) |
| `:delete` | `DELETE` (including `WITH ... DELETE`) |
| `:merge` | `MERGE` (including `WITH ... MERGE`) |
| `:values` | `VALUES` |

## Limitations

pgsqlarbiter is not sufficient security on its own. It is designed to be an additional layer on top of using a heavily restricted PostgreSQL user.

* pgsqlarbiter uses its own SQL parser. A potential weakness is a mismatch between the pgsqlarbiter and PostgreSQL SQL parsers.
* Operators and type casts are implemented via functions. These pass through without filtering.
* Identifiers containing dots are rejected.
