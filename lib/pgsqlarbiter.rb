# frozen_string_literal: true

require_relative "pgsqlarbiter/version"
require_relative "pgsqlarbiter/error"
require_relative "pgsqlarbiter/token"
require_relative "pgsqlarbiter/keywords"
require_relative "pgsqlarbiter/result"
require_relative "pgsqlarbiter/lexer"
require_relative "pgsqlarbiter/analyzer"

module Pgsqlarbiter
  def self.analyze(sql)
    Analyzer.new.analyze(sql)
  end

  def self.allowed?(sql, tables:, functions:)
    result = analyze(sql)
    allowed_tables = Set.new(tables)
    allowed_functions = Set.new(functions)
    result.tables.all? { |t| allowed_tables.include?(t) } &&
      result.functions.all? { |f| allowed_functions.include?(f) }
  end
end
