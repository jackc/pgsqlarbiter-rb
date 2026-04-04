# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  # Reusable query permission checker with pre-configured whitelists.
  #
  # Use this class when you need to check multiple queries against the same set of
  # allowed statement types, tables, and functions. For one-off checks, see
  # {Pgsqlarbiter.allow?}.
  class Arbiter
    # @return [Set<Symbol>] the set of valid statement type symbols
    VALID_STATEMENT_TYPES = Set[:select, :insert, :update, :delete, :merge, :values].freeze

    # @return [Set<Symbol>] allowed statement types
    attr_reader :statement_types
    # @return [Set<String>] allowed table and view names
    attr_reader :tables
    # @return [Set<String>] allowed function names
    attr_reader :functions

    # Create a new Arbiter with the given whitelists.
    #
    # @param statement_types [Array<Symbol>] allowed statement types. Valid values:
    #   +:select+, +:insert+, +:update+, +:delete+, +:merge+, +:values+
    # @param tables [Array<String>] allowed table and view names
    # @param functions [Array<String>, Set<String>] allowed function names
    #   (default: {Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS})
    # @raise [ArgumentError] if any statement type is not in {VALID_STATEMENT_TYPES}
    def initialize(statement_types:, tables:, functions: Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS)
      @statement_types = validate_statement_types(statement_types)
      @tables = Set.new(tables).freeze
      @functions = Set.new(functions).freeze
    end

    # Judge a SQL query against this arbiter's rules, returning a {Verdict} that
    # explains which checks passed or failed.
    #
    # @param sql [String] the SQL query to judge
    # @return [Verdict] detailed result with {Verdict#allowed?}, individual check
    #   results, and {Verdict#reasons}
    # @raise [ParseError] if the SQL cannot be parsed
    # @raise [MultipleStatementsError] if the SQL contains more than one statement
    # @raise [DisallowedStatementError] if the statement type is not a supported DML type
    def judge(sql)
      result = Pgsqlarbiter.analyze(sql)
      stmt_ok = @statement_types.include?(result.statement_type)
      bad_tables = result.tables.reject { |t| @tables.include?(t) }.freeze
      bad_functions = result.functions.reject { |f| @functions.include?(f) }.freeze

      Verdict.new(
        allowed: stmt_ok && bad_tables.empty? && bad_functions.empty?,
        statement_type_allowed: stmt_ok,
        statement_type: result.statement_type,
        disallowed_tables: bad_tables,
        disallowed_functions: bad_functions
      )
    end

    # Check whether a SQL query is allowed under this arbiter's rules.
    #
    # @param sql [String] the SQL query to check
    # @return [Boolean] +true+ if the statement type, all tables, and all functions
    #   are within the configured whitelists
    # @raise [ParseError] if the SQL cannot be parsed
    # @raise [MultipleStatementsError] if the SQL contains more than one statement
    # @raise [DisallowedStatementError] if the statement type is not a supported DML type
    def allow?(sql)
      judge(sql).allowed?
    end

    private

    def validate_statement_types(types)
      set = Set.new(types)
      invalid = set - VALID_STATEMENT_TYPES
      unless invalid.empty?
        raise ArgumentError, "unknown statement type(s): #{invalid.map(&:inspect).join(", ")}. " \
                             "Valid types: #{VALID_STATEMENT_TYPES.map(&:inspect).join(", ")}"
      end
      set.freeze
    end
  end
end
