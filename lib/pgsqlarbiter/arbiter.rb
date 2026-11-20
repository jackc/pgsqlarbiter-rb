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

    # @return [Schema] the tables and columns that exist in the database
    attr_reader :schema
    # @return [Set<Symbol>] allowed statement types
    attr_reader :allowed_statement_types
    # @return [Set<String>] allowed table and view names
    attr_reader :allowed_tables
    # @return [Hash{String => Symbol, Set<String>}] for each allowed table,
    #   +:all+ or the set of allowed column names
    attr_reader :allowed_columns
    # @return [Set<String>] allowed function names
    attr_reader :allowed_functions
    # @return [Set<String>] allowed type names
    attr_reader :allowed_types

    # Create a new Arbiter with the given whitelists.
    #
    # @param schema [Schema] the tables and columns that exist in the database.
    #   A table that is not in the schema is always denied
    # @param allowed_statement_types [Array<Symbol>] allowed statement types. Valid values:
    #   +:select+, +:insert+, +:update+, +:delete+, +:merge+, +:values+
    # @param allowed_tables [Array<String>, Hash{String => Symbol, Array<String>}] allowed
    #   table and view names. A Hash restricts columns: each value is +:all+ or the list
    #   of column names that may be used, whether read or written. A table with a column
    #   list cannot be used with +*+, a whole-row reference, +NATURAL JOIN+ or an
    #   +INSERT+ without a column list; queries must name the columns they use
    # @param allowed_functions [Array<String>, Set<String>] allowed function names
    #   (default: {Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS})
    # @param allowed_types [Array<String>, Set<String>] allowed type names for casts,
    #   typed literals and column definition lists
    #   (default: {Pgsqlarbiter::DEFAULT_QUERY_TYPES})
    # @raise [ArgumentError] if any statement type is not in {VALID_STATEMENT_TYPES}, or
    #   an allowed table or column is not in the schema
    def initialize(schema:, allowed_statement_types:, allowed_tables:,
      allowed_functions: Pgsqlarbiter::DEFAULT_QUERY_FUNCTIONS,
      allowed_types: Pgsqlarbiter::DEFAULT_QUERY_TYPES)
      raise ArgumentError, "schema must be a Pgsqlarbiter::Schema" unless schema.is_a?(Schema)

      @schema = schema
      @allowed_statement_types = validate_statement_types(allowed_statement_types)
      @allowed_columns = validate_tables(allowed_tables)
      @allowed_tables = Set.new(@allowed_columns.keys).freeze
      @allowed_functions = Set.new(allowed_functions).freeze
      @allowed_types = Set.new(allowed_types).freeze
    end

    # Judge a SQL query against this arbiter's rules, returning a {Verdict} that
    # explains which checks passed or failed.
    #
    # @param sql [String] the SQL query to judge
    # @return [Verdict] detailed result with {Verdict#allowed?}, individual check
    #   results, and {Verdict#reasons}
    # @raise [LexError] if the SQL cannot be tokenized
    # @raise [ParseError] if the SQL is not valid, supported syntax
    # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
    # @raise [MultipleStatementsError] if the SQL contains more than one statement
    # @raise [DisallowedStatementError] if the statement type is not a supported DML type
    def judge(sql)
      result = Pgsqlarbiter.analyze(sql, schema: @schema)
      bad_statement_types = result.statement_types.reject { |t| @allowed_statement_types.include?(t) }.freeze
      bad_tables = result.tables.reject { |t| @allowed_columns.key?(t) }.freeze
      # Columns of a table that is not allowed are covered by the table itself.
      bad_columns = result.columns.reject do |c|
        table, _, column = c.rpartition(".")
        allowed = @allowed_columns[table]
        allowed.nil? || allowed == :all || allowed.include?(column)
      end.freeze
      bad_functions = result.functions.reject { |f| @allowed_functions.include?(f) }.freeze
      bad_types = result.types.reject { |t| @allowed_types.include?(t) }.freeze

      Verdict.new(
        allowed: bad_statement_types.empty? && bad_tables.empty? && bad_columns.empty? &&
          bad_functions.empty? && bad_types.empty?,
        statement_type_allowed: bad_statement_types.empty?,
        statement_type: result.statement_type,
        disallowed_statement_types: bad_statement_types,
        disallowed_tables: bad_tables,
        disallowed_columns: bad_columns,
        disallowed_functions: bad_functions,
        disallowed_types: bad_types
      )
    end

    # Check whether a SQL query is allowed under this arbiter's rules.
    #
    # @param sql [String] the SQL query to check
    # @return [Boolean] +true+ if every statement type, table, column, function and type
    #   is within the configured whitelists
    # @raise [LexError] if the SQL cannot be tokenized
    # @raise [ParseError] if the SQL is not valid, supported syntax
    # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
    # @raise [MultipleStatementsError] if the SQL contains more than one statement
    # @raise [DisallowedStatementError] if the statement type is not a supported DML type
    def allow?(sql)
      judge(sql).allowed?
    end

    private

    # A table or column that is whitelisted but missing from the schema is a
    # mistake in one or the other; refusing to start is better than silently
    # never allowing it.
    def validate_tables(tables)
      tables = tables.to_h { |table| [table, :all] } unless tables.is_a?(Hash)
      allowed = {}
      tables.each do |table, columns|
        table = table.to_s
        raise ArgumentError, "allowed table #{table.inspect} is not in the schema" unless @schema.table?(table)

        allowed[table] =
          if columns == :all
            :all
          elsif columns.respond_to?(:to_ary) || columns.is_a?(Set)
            columns = Set.new(columns.map(&:to_s))
            unknown = columns.reject { |column| @schema.column?(table, column) }
            unless unknown.empty?
              raise ArgumentError, "allowed column(s) #{unknown.map(&:inspect).join(", ")} of table " \
                                   "#{table.inspect} are not in the schema"
            end
            columns.freeze
          else
            raise ArgumentError, "allowed columns of #{table.inspect} must be :all or a list of column names"
          end
      end
      allowed.freeze
    end

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
