# frozen_string_literal: true

module Pgsqlarbiter
  # Immutable token produced by the {Lexer}.
  #
  # @!attribute [r] type
  #   @return [Symbol, String] the grammar terminal: a Symbol named as in
  #     PostgreSQL's grammar (+:SELECT+, +:IDENT+, +:SCONST+, ...) or, for
  #     single-character tokens, the character itself (+"("+, +","+, ...)
  # @!attribute [r] value
  #   @return [String] the token's value: the folded identifier, the lower-case
  #     keyword, the literal's content, or the operator text
  # @!attribute [r] position
  #   @return [Integer] byte offset of the token in the original SQL string
  Token = Data.define(:type, :value, :position)

  # A node of the concrete syntax tree built by the {Parser}: one per grammar
  # production that was applied.
  #
  # @!attribute [r] name
  #   @return [Symbol] the production's nonterminal, named as in PostgreSQL's grammar
  # @!attribute [r] children
  #   @return [Array<Node, Token>] the production's right-hand side, in order
  Node = Struct.new(:name, :children)
end
