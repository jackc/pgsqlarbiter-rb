# frozen_string_literal: true

module Pgsqlarbiter
  Result = Data.define(:statement_type, :tables, :functions)
end
