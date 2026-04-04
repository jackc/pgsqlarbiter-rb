# frozen_string_literal: true

module Pgsqlarbiter
  # Immutable result of analyzing a SQL query.
  #
  # @!attribute [r] statement_type
  #   @return [Symbol] the statement type (+:select+, +:insert+, +:update+,
  #     +:delete+, +:merge+, or +:values+)
  # @!attribute [r] tables
  #   @return [Array<String>] sorted list of referenced table and view names
  # @!attribute [r] functions
  #   @return [Array<String>] sorted list of called function names
  Result = Data.define(:statement_type, :tables, :functions)
end
