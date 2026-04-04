# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  module Keywords
    ALLOWED_STATEMENT_TYPES = Set[
      "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "VALUES", "WITH"
    ].freeze

    # Keywords that take parentheses but are NOT function calls
    NON_FUNCTION_KEYWORDS = Set[
      "EXISTS", "CASE", "CAST", "IN", "NOT", "ANY", "ALL", "SOME",
      "ARRAY", "ROW", "VALUES", "LATERAL", "TABLE"
    ].freeze

    # Keywords that ARE function calls despite being reserved words
    FUNCTION_KEYWORDS = Set[
      "COALESCE", "NULLIF", "GREATEST", "LEAST", "EXTRACT",
      "TRIM", "SUBSTRING", "OVERLAY", "POSITION", "NORMALIZE", "GROUPING",
      "XMLELEMENT", "XMLFOREST", "XMLPARSE", "XMLROOT", "XMLSERIALIZE"
    ].freeze

    # Complete set of keywords the lexer recognizes
    ALL = Set[
      # Statement types
      "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "VALUES", "WITH",
      # Disallowed statement types (rejected by analyzer)
      "CREATE", "DROP", "ALTER", "TRUNCATE", "GRANT", "REVOKE",
      "SHOW", "SET", "RESET",
      "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
      "PREPARE", "EXECUTE", "DEALLOCATE",
      "LISTEN", "NOTIFY", "UNLISTEN",
      "LOAD", "COPY", "VACUUM", "ANALYZE", "CLUSTER", "REINDEX",
      "LOCK", "DISCARD", "COMMENT", "SECURITY", "REASSIGN", "REFRESH",
      "IMPORT", "CALL", "DO", "EXPLAIN",
      # Structural keywords
      "FROM", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS",
      "NATURAL", "OUTER", "ON", "USING", "INTO", "AS",
      "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH",
      "UNION", "INTERSECT", "EXCEPT",
      "ALL", "DISTINCT", "LATERAL", "ONLY", "TABLE",
      "RETURNING", "RECURSIVE", "COLUMNS",
      "NOT", "MATERIALIZED",
      "MATCHED", "WHEN", "THEN", "BY", "CONFLICT",
      "AND", "OR", "IS", "IN", "BETWEEN",
      "LIKE", "ILIKE", "SIMILAR",
      "CASE", "CAST", "END", "ELSE",
      "EXISTS", "ANY", "SOME", "ARRAY", "ROW",
      "WINDOW", "OVER", "PARTITION", "WITHIN", "FILTER",
      "NOTHING",
      "FOR", "IF", "ELSE", "TRUE", "FALSE", "NULL",
      "ASC", "DESC", "NULLS", "FIRST", "LAST",
      # Function keywords
      "COALESCE", "NULLIF", "GREATEST", "LEAST", "EXTRACT",
      "TRIM", "SUBSTRING", "OVERLAY", "POSITION", "NORMALIZE", "GROUPING",
      "XMLELEMENT", "XMLFOREST", "XMLPARSE", "XMLROOT", "XMLSERIALIZE",
      # Type keywords (common)
      "INT", "INTEGER", "BIGINT", "SMALLINT", "REAL", "FLOAT",
      "DOUBLE", "PRECISION", "NUMERIC", "DECIMAL",
      "CHAR", "CHARACTER", "VARCHAR", "TEXT",
      "BOOLEAN", "DATE", "TIME", "TIMESTAMP", "INTERVAL",
      "BOTH", "LEADING", "TRAILING"
    ].freeze
  end
end
