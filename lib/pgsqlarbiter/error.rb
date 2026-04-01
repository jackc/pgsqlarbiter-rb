# frozen_string_literal: true

module Pgsqlarbiter
  class Error < StandardError; end
  class LexError < Error; end
  class ParseError < Error; end
  class MultipleStatementsError < Error; end
  class DisallowedStatementError < Error; end
end
