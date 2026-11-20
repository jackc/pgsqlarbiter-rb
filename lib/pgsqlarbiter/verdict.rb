# frozen_string_literal: true

module Pgsqlarbiter
  # Immutable result of judging a SQL query against an {Arbiter}'s rules.
  #
  # A +Verdict+ tells you whether a query is allowed and, if not, exactly which
  # checks failed. Use {#allowed?} for a quick boolean, {#reasons} for
  # human-readable denial strings, or the individual fields for programmatic
  # branching.
  #
  # @!attribute [r] allowed
  #   @return [Boolean] +true+ when the query passes all checks
  # @!attribute [r] statement_type_allowed
  #   @return [Boolean] +true+ when every statement type the query needs is in
  #     the whitelist
  # @!attribute [r] statement_type
  #   @return [Symbol] the type of the statement itself
  # @!attribute [r] disallowed_statement_types
  #   @return [Array<Symbol>] statement types the query needs that are not
  #     whitelisted. This can include types other than {#statement_type}: a
  #     +SELECT+ with a +DELETE+ in its +WITH+ clause needs +:delete+
  # @!attribute [r] disallowed_tables
  #   @return [Array<String>] tables referenced by the query that are not whitelisted
  # @!attribute [r] disallowed_columns
  #   @return [Array<String>] columns of allowed tables that the query uses and
  #     that are not whitelisted, as +table.column+. +table.*+ means the query
  #     uses every column of a table whose columns are restricted
  # @!attribute [r] disallowed_functions
  #   @return [Array<String>] functions called by the query that are not whitelisted
  # @!attribute [r] disallowed_types
  #   @return [Array<String>] types named by the query that are not whitelisted
  Verdict = Data.define(:allowed, :statement_type_allowed, :statement_type,
    :disallowed_statement_types, :disallowed_tables, :disallowed_columns, :disallowed_functions,
    :disallowed_types) do
    def initialize(allowed:, statement_type_allowed:, statement_type:, disallowed_tables:, disallowed_functions:,
      disallowed_statement_types: nil, disallowed_types: [].freeze, disallowed_columns: [].freeze)
      disallowed_statement_types ||= (statement_type_allowed ? [] : [statement_type]).freeze
      super
    end

    alias_method :allowed?, :allowed
    alias_method :statement_type_allowed?, :statement_type_allowed

    # Human-readable denial reasons. Empty when the query is allowed.
    #
    # @return [Array<String>] frozen list of reason strings
    def reasons
      r = []
      disallowed_statement_types.each { |t| r << "statement type :#{t} is not allowed" }
      disallowed_tables.each { |t| r << "table #{t.inspect} is not allowed" }
      disallowed_columns.each do |c|
        table, _, column = c.rpartition(".")
        r << if column == "*"
          "using every column of table #{table.inspect} (*, a whole-row reference, or an implicit column list) " \
            "is not allowed because its columns are restricted"
        else
          "column #{c.inspect} is not allowed"
        end
      end
      disallowed_functions.each { |f| r << "function #{f.inspect} is not allowed" }
      disallowed_types.each { |t| r << "type #{t.inspect} is not allowed" }
      r.freeze
    end
  end
end
