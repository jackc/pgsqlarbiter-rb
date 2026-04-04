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
  #   @return [Boolean] +true+ when the statement type is in the whitelist
  # @!attribute [r] statement_type
  #   @return [Symbol] the query's actual statement type
  # @!attribute [r] disallowed_tables
  #   @return [Array<String>] tables referenced by the query that are not whitelisted
  # @!attribute [r] disallowed_functions
  #   @return [Array<String>] functions called by the query that are not whitelisted
  Verdict = Data.define(:allowed, :statement_type_allowed, :statement_type,
                        :disallowed_tables, :disallowed_functions) do
    alias_method :allowed?, :allowed
    alias_method :statement_type_allowed?, :statement_type_allowed

    # Human-readable denial reasons. Empty when the query is allowed.
    #
    # @return [Array<String>] frozen list of reason strings
    def reasons
      r = []
      r << "statement type :#{statement_type} is not allowed" unless statement_type_allowed
      disallowed_tables.each { |t| r << "table #{t.inspect} is not allowed" }
      disallowed_functions.each { |f| r << "function #{f.inspect} is not allowed" }
      r.freeze
    end
  end
end
