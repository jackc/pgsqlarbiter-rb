# frozen_string_literal: true

module Pgsqlarbiter
  # Immutable token produced by the {Lexer}.
  #
  # @!attribute [r] type
  #   @return [Symbol] token type (one of the {TokenType} constants)
  # @!attribute [r] value
  #   @return [String, nil] the token text (+nil+ for EOF)
  # @!attribute [r] position
  #   @return [Integer] character offset in the original SQL string
  Token = Data.define(:type, :value, :position)

  # Constants for all token types produced by the {Lexer}.
  module TokenType
    KEYWORD      = :keyword
    IDENT        = :ident
    QUOTED_IDENT = :quoted_ident
    STRING       = :string
    NUMBER       = :number
    PARAM        = :param
    LPAREN       = :lparen
    RPAREN       = :rparen
    LBRACKET     = :lbracket
    RBRACKET     = :rbracket
    COMMA        = :comma
    DOT          = :dot
    SEMICOLON    = :semicolon
    STAR         = :star
    TYPECAST     = :typecast
    OP           = :op
    EOF          = :eof
  end
end
