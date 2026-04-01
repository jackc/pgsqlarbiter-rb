# pgsqlarbiter

pgsqlarbiter is SQL query permission system for PostgreSQL. It is designed for granting semi-trusted users access to a PostgreSQL database. PostgreSQL's permission system is a necessary foundation, but further restrictions are often required. pgsqlarbiter adds the following:

* Only single statement DML (SELECT, INSERT, UPDATE, DELETE, MERGE, or VALUES) queries are allowed.
* All referenced tables, views, and named functions must be whitelisted.

These additional restrictions close many unexpected difficult or impossible to restrict with the PostgreSQL permission system such as:

* Exposure of system information via `information_schema` or `pg_catalog`.
* Exposure of system information via `SHOW`.
* Transactions that can block other users.
* `SET` can disable restrictions such as `statement_timeout`.
* Unexpected access to dangerous built-in functions like `set_config`, `pg_sleep`, `lo_*`, `pg_advisory_lock`, and `pg_notify`.


## Limitations

pgsqlarbiter is not sufficient security on its own. It is designed to be an additional layer on top of using a heavily restricted PostgreSQL user.

* pgsqlarbiter uses its own SQL parser. A potential weakness is a mismatch between the pgsqlarbiter and PostgreSQL SQL parsers.
* Operators and type casts are implemented via functions. These pass through without filtering.
* Identifiers with containing dots are rejected.
