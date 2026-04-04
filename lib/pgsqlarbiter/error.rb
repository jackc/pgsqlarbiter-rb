# frozen_string_literal: true

module Pgsqlarbiter
  # Base error class for all pgsqlarbiter errors.
  class Error < StandardError; end

  # Raised when the lexer encounters invalid syntax (e.g. unterminated strings or unexpected characters).
  class LexError < Error; end

  # Raised when the analyzer encounters invalid or unparseable SQL structure.
  class ParseError < Error; end

  # Raised when the SQL contains more than one statement.
  class MultipleStatementsError < Error; end

  # Raised when the statement type is not a supported DML type (e.g. DDL, DCL, or TCL).
  class DisallowedStatementError < Error; end
end
