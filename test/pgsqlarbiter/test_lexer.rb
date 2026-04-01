# frozen_string_literal: true

require_relative "../test_helper"

class TestLexer < Minitest::Test
  def setup
    @lexer = Pgsqlarbiter::Lexer.new
  end

  def token_types(sql)
    @lexer.tokenize(sql).map(&:type)
  end

  def token_values(sql)
    @lexer.tokenize(sql).map(&:value)
  end

  def tokens(sql)
    @lexer.tokenize(sql)
  end

  # --- Basic token types ---

  def test_keyword
    toks = tokens("SELECT")
    assert_equal :keyword, toks[0].type
    assert_equal "SELECT", toks[0].value
    assert_equal :eof, toks[1].type
  end

  def test_keyword_case_insensitive
    toks = tokens("select")
    assert_equal :keyword, toks[0].type
    assert_equal "SELECT", toks[0].value
  end

  def test_keyword_mixed_case
    toks = tokens("SeLeCt")
    assert_equal :keyword, toks[0].type
    assert_equal "SELECT", toks[0].value
  end

  def test_identifier
    toks = tokens("my_table")
    assert_equal :ident, toks[0].type
    assert_equal "my_table", toks[0].value
  end

  def test_identifier_lowercased
    toks = tokens("MyTable")
    assert_equal :ident, toks[0].type
    assert_equal "mytable", toks[0].value
  end

  def test_quoted_identifier
    toks = tokens('"MyTable"')
    assert_equal :quoted_ident, toks[0].type
    assert_equal "MyTable", toks[0].value
  end

  def test_quoted_identifier_escaped_quote
    toks = tokens('"my""table"')
    assert_equal :quoted_ident, toks[0].type
    assert_equal 'my"table', toks[0].value
  end

  def test_quoted_identifier_keyword_name
    toks = tokens('"SELECT"')
    assert_equal :quoted_ident, toks[0].type
    assert_equal "SELECT", toks[0].value
  end

  def test_schema_qualified
    types = token_types("schema.table_name")
    assert_equal [:ident, :dot, :ident, :eof], types
  end

  # --- Numbers ---

  def test_integer
    toks = tokens("42")
    assert_equal :number, toks[0].type
    assert_equal "42", toks[0].value
  end

  def test_float
    toks = tokens("3.14")
    assert_equal :number, toks[0].type
    assert_equal "3.14", toks[0].value
  end

  def test_scientific_notation
    toks = tokens("1e10")
    assert_equal :number, toks[0].type
    assert_equal "1e10", toks[0].value
  end

  def test_scientific_notation_with_sign
    toks = tokens("2.5e-3")
    assert_equal :number, toks[0].type
    assert_equal "2.5e-3", toks[0].value
  end

  def test_hex_number
    toks = tokens("0xFF")
    assert_equal :number, toks[0].type
    assert_equal "0xFF", toks[0].value
  end

  def test_octal_number
    toks = tokens("0o77")
    assert_equal :number, toks[0].type
    assert_equal "0o77", toks[0].value
  end

  def test_binary_number
    toks = tokens("0b101")
    assert_equal :number, toks[0].type
    assert_equal "0b101", toks[0].value
  end

  def test_number_with_underscores
    toks = tokens("1_000_000")
    assert_equal :number, toks[0].type
    assert_equal "1_000_000", toks[0].value
  end

  def test_leading_dot_number
    toks = tokens(".5")
    assert_equal :number, toks[0].type
    assert_equal ".5", toks[0].value
  end

  # --- Parameters ---

  def test_parameter_placeholder
    toks = tokens("$1")
    assert_equal :param, toks[0].type
    assert_equal "$1", toks[0].value
  end

  def test_parameter_multi_digit
    toks = tokens("$42")
    assert_equal :param, toks[0].type
    assert_equal "$42", toks[0].value
  end

  # --- Typecast ---

  def test_typecast
    toks = tokens("::")
    assert_equal :typecast, toks[0].type
    assert_equal "::", toks[0].value
  end

  # --- Operators ---

  def test_operator_plus
    toks = tokens("+")
    assert_equal :op, toks[0].type
    assert_equal "+", toks[0].value
  end

  def test_operator_gte
    toks = tokens(">=")
    assert_equal :op, toks[0].type
    assert_equal ">=", toks[0].value
  end

  def test_operator_ne
    toks = tokens("<>")
    assert_equal :op, toks[0].type
    assert_equal "<>", toks[0].value
  end

  def test_operator_concat
    toks = tokens("||")
    assert_equal :op, toks[0].type
    assert_equal "||", toks[0].value
  end

  def test_operator_not_equal
    toks = tokens("!=")
    assert_equal :op, toks[0].type
    assert_equal "!=", toks[0].value
  end

  # --- Punctuation ---

  def test_lparen
    assert_equal [:lparen, :eof], token_types("(")
  end

  def test_rparen
    assert_equal [:rparen, :eof], token_types(")")
  end

  def test_lbracket
    assert_equal [:lbracket, :eof], token_types("[")
  end

  def test_rbracket
    assert_equal [:rbracket, :eof], token_types("]")
  end

  def test_comma
    assert_equal [:comma, :eof], token_types(",")
  end

  def test_dot
    assert_equal [:dot, :eof], token_types(".")
  end

  def test_semicolon
    assert_equal [:semicolon, :eof], token_types(";")
  end

  def test_star
    assert_equal [:star, :eof], token_types("*")
  end

  def test_eof_always_appended
    assert_equal [:eof], token_types("")
  end

  # --- String literals ---

  def test_simple_string
    toks = tokens("'hello'")
    assert_equal :string, toks[0].type
    assert_equal "hello", toks[0].value
  end

  def test_escaped_single_quote
    toks = tokens("'it''s'")
    assert_equal :string, toks[0].type
    assert_equal "it''s", toks[0].value
  end

  def test_empty_string
    toks = tokens("''")
    assert_equal :string, toks[0].type
    assert_equal "", toks[0].value
  end

  def test_e_string
    toks = tokens("E'line\\nbreak'")
    assert_equal :string, toks[0].type
  end

  def test_e_string_lowercase
    toks = tokens("e'tab\\there'")
    assert_equal :string, toks[0].type
  end

  def test_e_string_escaped_backslash
    toks = tokens("E'path\\\\here'")
    assert_equal :string, toks[0].type
  end

  def test_e_string_escaped_quote
    toks = tokens("E'it\\'s'")
    assert_equal :string, toks[0].type
  end

  def test_b_string
    toks = tokens("B'101'")
    assert_equal :string, toks[0].type
  end

  def test_b_string_lowercase
    toks = tokens("b'010'")
    assert_equal :string, toks[0].type
  end

  def test_x_string
    toks = tokens("X'FF'")
    assert_equal :string, toks[0].type
  end

  def test_x_string_lowercase
    toks = tokens("x'0a'")
    assert_equal :string, toks[0].type
  end

  def test_dollar_quoted_string
    toks = tokens("$$body$$")
    assert_equal :string, toks[0].type
    assert_equal "body", toks[0].value
  end

  def test_dollar_quoted_with_tag
    toks = tokens("$tag$body$tag$")
    assert_equal :string, toks[0].type
    assert_equal "body", toks[0].value
  end

  def test_dollar_quoted_nested_different_tags
    toks = tokens("$a$content $b$inner$b$ more$a$")
    assert_equal :string, toks[0].type
    assert_equal "content $b$inner$b$ more", toks[0].value
  end

  def test_dollar_quoted_containing_semicolons
    toks = tokens("$$hello; world$$")
    assert_equal :string, toks[0].type
    assert_equal "hello; world", toks[0].value
  end

  def test_dollar_quoted_containing_sql_keywords
    toks = tokens("$$SELECT * FROM t$$")
    assert_equal :string, toks[0].type
    assert_equal "SELECT * FROM t", toks[0].value
  end

  def test_empty_dollar_quoted
    toks = tokens("$$$$")
    assert_equal :string, toks[0].type
    assert_equal "", toks[0].value
  end

  def test_unterminated_single_quoted_string
    assert_raises(Pgsqlarbiter::LexError) { tokens("'hello") }
  end

  def test_unterminated_e_string
    assert_raises(Pgsqlarbiter::LexError) { tokens("E'hello") }
  end

  def test_unterminated_dollar_quoted_string
    assert_raises(Pgsqlarbiter::LexError) { tokens("$$hello") }
  end

  def test_unterminated_quoted_identifier
    assert_raises(Pgsqlarbiter::LexError) { tokens('"hello') }
  end

  def test_e_not_followed_by_quote_is_identifier
    toks = tokens("e")
    assert_equal :ident, toks[0].type
    assert_equal "e", toks[0].value
  end

  def test_e_followed_by_space_then_quote
    # "e 'hello'" — e is identifier, 'hello' is separate string
    toks = tokens("e 'hello'")
    assert_equal :ident, toks[0].type
    assert_equal "e", toks[0].value
    assert_equal :string, toks[1].type
    assert_equal "hello", toks[1].value
  end

  # --- U& string and identifier prefixes ---

  def test_u_and_string
    toks = tokens("U&'unicode'")
    assert_equal :string, toks[0].type
  end

  def test_u_and_quoted_identifier
    toks = tokens('U&"unicode"')
    assert_equal :quoted_ident, toks[0].type
  end

  # --- Comments ---

  def test_line_comment
    types = token_types("SELECT 1 -- comment")
    assert_equal [:keyword, :number, :eof], types
  end

  def test_block_comment
    types = token_types("SELECT /* comment */ 1")
    assert_equal [:keyword, :number, :eof], types
  end

  def test_nested_block_comment
    types = token_types("SELECT /* outer /* inner */ still comment */ 1")
    assert_equal [:keyword, :number, :eof], types
  end

  def test_deeply_nested_block_comment
    types = token_types("/* /* /* deep */ */ */")
    assert_equal [:eof], types
  end

  def test_unterminated_block_comment
    assert_raises(Pgsqlarbiter::LexError) { tokens("/* unterminated") }
  end

  def test_comment_like_inside_string
    toks = tokens("'not -- a comment'")
    assert_equal 2, toks.length # STRING + EOF
    assert_equal :string, toks[0].type
  end

  def test_block_comment_like_inside_string
    toks = tokens("'not /* a */ comment'")
    assert_equal 2, toks.length # STRING + EOF
    assert_equal :string, toks[0].type
  end

  # --- Whitespace ---

  def test_multiple_whitespace
    types = token_types("SELECT  \t  \n  1")
    assert_equal [:keyword, :number, :eof], types
  end

  def test_no_whitespace_between_tokens
    types = token_types("SELECT*FROM")
    assert_equal [:keyword, :star, :keyword, :eof], types
  end

  # --- Empty/whitespace/comment-only input ---

  def test_empty_input
    assert_equal [:eof], token_types("")
  end

  def test_whitespace_only
    assert_equal [:eof], token_types("   \t\n  ")
  end

  def test_comment_only
    assert_equal [:eof], token_types("-- just a comment")
  end

  def test_block_comment_only
    assert_equal [:eof], token_types("/* comment */")
  end

  # --- Invalid characters ---

  def test_invalid_character
    assert_raises(Pgsqlarbiter::LexError) { tokens("\x00") }
  end

  # --- Position tracking ---

  def test_position_tracking
    toks = tokens("SELECT 1")
    assert_equal 0, toks[0].position
    assert_equal 7, toks[1].position
  end

  # --- Complex sequences ---

  def test_full_select_statement
    types = token_types("SELECT * FROM users WHERE id = $1")
    assert_equal [:keyword, :star, :keyword, :ident, :keyword, :ident, :op, :param, :eof], types
  end

  def test_typecast_in_expression
    types = token_types("x::int")
    assert_equal [:ident, :typecast, :keyword, :eof], types
  end

  def test_schema_function_call
    types = token_types("schema.func(1)")
    assert_equal [:ident, :dot, :ident, :lparen, :number, :rparen, :eof], types
  end

  def test_single_colon
    assert_equal [:ident, :op, :ident, :eof], token_types("a:b")
  end
end
