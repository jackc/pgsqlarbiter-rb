# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  class Arbiter
    VALID_STATEMENT_TYPES = Set[:select, :insert, :update, :delete, :merge, :values].freeze

    attr_reader :statement_types, :tables, :functions

    def initialize(statement_types:, tables:, functions: Pgsqlarbiter::SAFE_FUNCTIONS)
      @statement_types = validate_statement_types(statement_types)
      @tables = Set.new(tables).freeze
      @functions = Set.new(functions).freeze
    end

    def allow?(sql)
      result = Pgsqlarbiter.analyze(sql)
      @statement_types.include?(result.statement_type) &&
        result.tables.all? { |t| @tables.include?(t) } &&
        result.functions.all? { |f| @functions.include?(f) }
    end

    private

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
