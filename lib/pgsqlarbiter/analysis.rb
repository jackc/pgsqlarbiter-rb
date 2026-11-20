# frozen_string_literal: true

module Pgsqlarbiter
  # Immutable result of analyzing a SQL query.
  #
  # @!attribute [r] statement_type
  #   @return [Symbol] the type of the statement itself (+:select+, +:insert+,
  #     +:update+, +:delete+, +:merge+, or +:values+)
  # @!attribute [r] statement_types
  #   @return [Array<Symbol>] sorted list of every statement type the query
  #     needs permission for: {#statement_type}, the type of each
  #     data-modifying statement inside a +WITH+ clause, and +:update+ when the
  #     query takes row locks (+FOR UPDATE+, +FOR SHARE+) or uses
  #     +ON CONFLICT DO UPDATE+
  # @!attribute [r] tables
  #   @return [Array<String>] sorted list of referenced table and view names
  # @!attribute [r] columns
  #   @return [Array<String>] sorted list of the table columns the query reads
  #     or writes, as +table.column+ with the table named as in {#tables}.
  #     +table.*+ stands for every column of the table: it is listed for +*+,
  #     for a whole-row reference such as +row_to_json(u)+, for +NATURAL JOIN+,
  #     for +INSERT+ without a column list, and for a table whose columns are
  #     renamed by a column alias list. Columns of tables that are missing
  #     from the {Schema} are not reliable; {Arbiter} denies such tables
  # @!attribute [r] functions
  #   @return [Array<String>] sorted list of called function names
  # @!attribute [r] types
  #   @return [Array<String>] sorted list of type names used in casts, typed
  #     literals and column definition lists
  Analysis = Data.define(:statement_type, :statement_types, :tables, :columns, :functions, :types)
end
