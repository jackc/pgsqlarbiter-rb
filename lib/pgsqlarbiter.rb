# frozen_string_literal: true

require_relative "pgsqlarbiter/version"
require_relative "pgsqlarbiter/error"
require_relative "pgsqlarbiter/token"
require_relative "pgsqlarbiter/keywords"
require_relative "pgsqlarbiter/analysis"
require_relative "pgsqlarbiter/schema"
require_relative "pgsqlarbiter/default_query_functions"
require_relative "pgsqlarbiter/default_query_types"
require_relative "pgsqlarbiter/lexer"
require_relative "pgsqlarbiter/parser"
require_relative "pgsqlarbiter/analyzer"
require_relative "pgsqlarbiter/verdict"
require_relative "pgsqlarbiter/arbiter"

# SQL query permission system for PostgreSQL.
#
# Pgsqlarbiter restricts database access for semi-trusted users by ensuring only
# single-statement DML queries are executed and all referenced tables, views, and
# functions are whitelisted.
module Pgsqlarbiter
  # Analyze a SQL query and extract its statement type(s), referenced tables and columns,
  # function calls, and type names.
  #
  # @param sql [String] the SQL query to analyze
  # @param schema [Schema] the tables and columns that exist in the database
  # @return [Analysis] analysis result
  # @raise [LexError] if the SQL cannot be tokenized
  # @raise [ParseError] if the SQL is not valid, supported syntax
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  # @raise [InternalError] if analysis fails because of a bug in pgsqlarbiter
  def self.analyze(sql, schema:)
    Analyzer.new(schema).analyze(sql)
  end

  # Judge a SQL query against the given restrictions, returning a {Verdict} that
  # explains which checks passed or failed.
  #
  # This is a convenience method that creates a one-off {Arbiter} instance. For repeated
  # checks with the same rules, prefer creating an {Arbiter} directly.
  #
  # @param sql [String] the SQL query to judge
  # @param schema [Schema] the tables and columns that exist in the database
  # @param allowed_tables [Array<String>, Hash] allowed table and view names, or a Hash of
  #   table name to +:all+ or the allowed column names
  # @param allowed_statement_types [Array<Symbol>] allowed statement types
  #   (default: +[:select]+). Valid types: +:select+, +:insert+, +:update+,
  #   +:delete+, +:merge+, +:values+
  # @param allowed_functions [Set<String>, Array<String>] allowed function names
  #   (default: {DEFAULT_QUERY_FUNCTIONS})
  # @param allowed_types [Set<String>, Array<String>] allowed type names
  #   (default: {DEFAULT_QUERY_TYPES})
  # @return [Verdict] detailed result with {Verdict#allowed?}, individual check
  #   results, and {Verdict#reasons}
  # @raise [ArgumentError] if a whitelisted table or column is not in the schema
  # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  # @raise [InternalError] if analysis fails because of a bug in pgsqlarbiter
  def self.judge(sql, schema:, allowed_tables:, allowed_statement_types: [:select],
    allowed_functions: DEFAULT_QUERY_FUNCTIONS, allowed_types: DEFAULT_QUERY_TYPES)
    Arbiter.new(schema: schema, allowed_statement_types: allowed_statement_types, allowed_tables: allowed_tables,
      allowed_functions: allowed_functions, allowed_types: allowed_types).judge(sql)
  end

  # Check whether a SQL query is allowed under the given restrictions.
  #
  # This is a convenience method that creates a one-off {Arbiter} instance. For repeated
  # checks with the same rules, prefer creating an {Arbiter} directly.
  #
  # @param sql [String] the SQL query to check
  # @param schema [Schema] the tables and columns that exist in the database
  # @param allowed_tables [Array<String>, Hash] allowed table and view names, or a Hash of
  #   table name to +:all+ or the allowed column names
  # @param allowed_statement_types [Array<Symbol>] allowed statement types
  #   (default: +[:select]+). Valid types: +:select+, +:insert+, +:update+,
  #   +:delete+, +:merge+, +:values+
  # @param allowed_functions [Set<String>, Array<String>] allowed function names
  #   (default: {DEFAULT_QUERY_FUNCTIONS})
  # @param allowed_types [Set<String>, Array<String>] allowed type names
  #   (default: {DEFAULT_QUERY_TYPES})
  # @return [Boolean] +true+ if the query is allowed, +false+ otherwise
  # @raise [ArgumentError] if a whitelisted table or column is not in the schema
  # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  # @raise [InternalError] if analysis fails because of a bug in pgsqlarbiter
  def self.allow?(sql, schema:, allowed_tables:, allowed_statement_types: [:select],
    allowed_functions: DEFAULT_QUERY_FUNCTIONS, allowed_types: DEFAULT_QUERY_TYPES)
    Arbiter.new(schema: schema, allowed_statement_types: allowed_statement_types, allowed_tables: allowed_tables,
      allowed_functions: allowed_functions, allowed_types: allowed_types).allow?(sql)
  end
end
