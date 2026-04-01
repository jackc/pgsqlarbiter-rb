# frozen_string_literal: true

module Pgsqlarbiter
  Token = Data.define(:type, :value, :position)

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
