# frozen_string_literal: true

require_relative "pgsqlarbiter/version"
require_relative "pgsqlarbiter/error"
require_relative "pgsqlarbiter/token"
require_relative "pgsqlarbiter/keywords"
require_relative "pgsqlarbiter/analysis"
require_relative "pgsqlarbiter/default_query_functions"
require_relative "pgsqlarbiter/lexer"
require_relative "pgsqlarbiter/analyzer"
require_relative "pgsqlarbiter/verdict"
require_relative "pgsqlarbiter/arbiter"

# SQL query permission system for PostgreSQL.
#
# Pgsqlarbiter restricts database access for semi-trusted users by ensuring only
# single-statement DML queries are executed and all referenced tables, views, and
# functions are whitelisted.
module Pgsqlarbiter
  # Analyze a SQL query and extract its statement type, referenced tables, and function calls.
  #
  # @param sql [String] the SQL query to analyze
  # @return [Analysis] analysis result containing statement_type, tables, and functions
  # @raise [ParseError] if the SQL cannot be parsed
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  def self.analyze(sql)
    Analyzer.new.analyze(sql)
  end

  # Judge a SQL query against the given restrictions, returning a {Verdict} that
  # explains which checks passed or failed.
  #
  # This is a convenience method that creates a one-off {Arbiter} instance. For repeated
  # checks with the same rules, prefer creating an {Arbiter} directly.
  #
  # @param sql [String] the SQL query to judge
  # @param allowed_tables [Array<String>] allowed table and view names
  # @param allowed_statement_types [Array<Symbol>] allowed statement types
  #   (default: +[:select]+). Valid types: +:select+, +:insert+, +:update+,
  #   +:delete+, +:merge+, +:values+
  # @param allowed_functions [Set<String>, Array<String>] allowed function names
  #   (default: {DEFAULT_QUERY_FUNCTIONS})
  # @return [Verdict] detailed result with {Verdict#allowed?}, individual check
  #   results, and {Verdict#reasons}
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  def self.judge(sql, allowed_tables:, allowed_statement_types: [:select], allowed_functions: DEFAULT_QUERY_FUNCTIONS)
    Arbiter.new(allowed_statement_types: allowed_statement_types, allowed_tables: allowed_tables, allowed_functions: allowed_functions).judge(sql)
  end

  # Check whether a SQL query is allowed under the given restrictions.
  #
  # This is a convenience method that creates a one-off {Arbiter} instance. For repeated
  # checks with the same rules, prefer creating an {Arbiter} directly.
  #
  # @param sql [String] the SQL query to check
  # @param allowed_tables [Array<String>] allowed table and view names
  # @param allowed_statement_types [Array<Symbol>] allowed statement types
  #   (default: +[:select]+). Valid types: +:select+, +:insert+, +:update+,
  #   +:delete+, +:merge+, +:values+
  # @param allowed_functions [Set<String>, Array<String>] allowed function names
  #   (default: {DEFAULT_QUERY_FUNCTIONS})
  # @return [Boolean] +true+ if the query is allowed, +false+ otherwise
  # @raise [MultipleStatementsError] if the SQL contains more than one statement
  # @raise [DisallowedStatementError] if the statement type is not a supported DML type
  def self.allow?(sql, allowed_tables:, allowed_statement_types: [:select], allowed_functions: DEFAULT_QUERY_FUNCTIONS)
    Arbiter.new(allowed_statement_types: allowed_statement_types, allowed_tables: allowed_tables, allowed_functions: allowed_functions).allow?(sql)
  end
end
