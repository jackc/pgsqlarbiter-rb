# frozen_string_literal: true

require_relative "pgsqlarbiter/version"
require_relative "pgsqlarbiter/error"
require_relative "pgsqlarbiter/token"
require_relative "pgsqlarbiter/keywords"
require_relative "pgsqlarbiter/result"
require_relative "pgsqlarbiter/safe_functions"
require_relative "pgsqlarbiter/lexer"
require_relative "pgsqlarbiter/analyzer"
require_relative "pgsqlarbiter/arbiter"

module Pgsqlarbiter
  def self.analyze(sql)
    Analyzer.new.analyze(sql)
  end

  def self.allow?(sql, tables:, statement_types: [:select], functions: SAFE_FUNCTIONS)
    Arbiter.new(statement_types: statement_types, tables: tables, functions: functions).allow?(sql)
  end
end
