# frozen_string_literal: true

require_relative "../test_helper"

# The lexer is a port of PostgreSQL's scan.l. These tests pin each rule, with
# particular attention to where a token starts and ends.
class TestLexer < Minitest::Test
  def tokens(sql)
    Pgsqlarbiter::Lexer.new.tokenize(sql)
  end

  def types(sql)
    tokens(sql).map(&:type)
  end

  def values(sql)
    tokens(sql).map(&:value)
  end

  def assert_lex_error(sql, message = nil)
    error = assert_raises(Pgsqlarbiter::LexError) { tokens(sql) }
    assert_match(message, error.message) if message
  end

  # --- Keywords and identifiers ---

  def test_keywords_are_case_insensitive
    assert_equal [:SELECT, :SELECT, :SELECT], types("SELECT select SeLeCt")
    assert_equal %w[select select select], values("SELECT select SeLeCt")
  end

  def test_keyword_tokens_use_grammar_names
    assert_equal [:DELETE_P, :IN_P, :NULL_P, :TRUE_P], types("delete in null true")
  end

  def test_identifier_is_folded_to_lower_case
    token = tokens("MyTable")[0]
    assert_equal :IDENT, token.type
    assert_equal "mytable", token.value
  end

  def test_quoted_identifier_keeps_case_and_is_never_a_keyword
    assert_equal [:IDENT, :IDENT], types('"MyTable" "select"')
    assert_equal %w[MyTable select], values('"MyTable" "select"')
  end

  def test_quoted_identifier_doubled_quote
    assert_equal ['a"b'], values('"a""b"')
  end

  def test_zero_length_quoted_identifier
    assert_lex_error('""', /zero-length/)
  end

  def test_unterminated_quoted_identifier
    assert_lex_error('"abc', /unterminated quoted identifier/)
  end

  def test_dollar_is_part_of_an_identifier
    assert_equal ["a$x$"], values("a$x$")
    assert_equal [:IDENT], types("a$x$")
  end

  def test_identifier_with_digits_and_underscore
    assert_equal ["_a1_b2"], values("_a1_b2")
  end

  def test_non_ascii_identifier_is_kept_as_written
    assert_equal ["été"], values("été")
  end

  def test_non_ascii_upper_case_in_unquoted_identifier_is_rejected
    assert_lex_error("École", /non-ASCII upper-case/)
    assert_equal ["École"], values('"École"')
  end

  def test_keywords_are_matched_with_ascii_folding_only
    # U+0131 (dotless i) upcases to "I" in Unicode, but PostgreSQL does not fold it.
    assert_equal [:IDENT], types("unıon")
    # U+212A (Kelvin sign) downcases to "k" in Unicode.
    assert_lex_error("Key")
  end

  def test_identifier_is_truncated_to_63_bytes
    assert_equal ["a" * 63], values("a" * 80)
    assert_equal ["b" * 63], values(%("#{"b" * 70}"))
  end

  def test_truncation_does_not_split_a_character
    name = "a" * 62 + "é"
    assert_equal ["a" * 62], values(name)
  end

  # --- Whitespace and comments ---

  def test_whitespace_and_empty_input
    assert_empty tokens("")
    assert_empty tokens(" \t\n\r\f\v")
  end

  def test_line_comment_ends_at_newline
    assert_equal [:SELECT, :ICONST], types("SELECT -- comment\n1")
  end

  def test_line_comment_ends_at_carriage_return
    assert_equal [:SELECT, :ICONST, :FROM, :IDENT], types("SELECT 1 --\rFROM secrets")
  end

  def test_line_comment_at_end_of_input
    assert_equal [:SELECT], types("SELECT -- no newline")
  end

  def test_block_comment
    assert_equal [:SELECT, :ICONST], types("SELECT /* x */ 1")
  end

  def test_block_comments_nest
    assert_equal [:SELECT, :ICONST], types("SELECT /* a /* b */ c */ 1")
  end

  def test_block_comment_edge_cases
    assert_empty tokens("/**/")
    assert_empty tokens("/*/ */")
    assert_empty tokens("/***/")
  end

  def test_unterminated_block_comment
    assert_lex_error("SELECT /* a /* b */", /unterminated/)
  end

  # --- String literals ---

  def test_plain_string
    token = tokens("'hello'")[0]
    assert_equal :SCONST, token.type
    assert_equal "hello", token.value
  end

  def test_doubled_quote_in_string
    assert_equal ["it's"], values("'it''s'")
  end

  def test_backslash_is_ordinary_in_plain_string
    assert_equal [:SCONST, :IDENT], types("'a\\' x")
  end

  def test_escape_string_backslash_quote
    assert_equal [:SCONST, :IDENT], types("E'it\\'s' x")
    assert_equal [:SCONST, :IDENT], types("e'a\\\\' x")
  end

  def test_unterminated_string
    assert_lex_error("'abc", /unterminated quoted string/)
    assert_lex_error("E'abc\\", /unterminated quoted string/)
    assert_lex_error("E'abc\\'", /unterminated quoted string/)
  end

  def test_bit_and_hex_strings
    assert_equal [:BCONST, :XCONST], types("B'101' X'1F'")
    assert_equal [:BCONST, :XCONST], types("b'101' x'1F'")
  end

  def test_bit_string_has_no_doubled_quote_escape
    assert_equal [:BCONST, :SCONST], types("B'1''0'")
  end

  def test_national_string_is_nchar_keyword_and_string
    assert_equal [:NCHAR, :SCONST], types("N'x'")
  end

  def test_prefix_letters_are_ordinary_identifiers_otherwise
    assert_equal [:IDENT, :SCONST], types("ne'x'")
    assert_equal [:IDENT, :IDENT, :IDENT, :IDENT], types("e b x n")
  end

  def test_string_continues_across_a_newline
    assert_equal ["ab"], values("'a'\n'b'")
    assert_equal ["ab"], values("'a'  \r\n  'b'")
  end

  def test_string_does_not_continue_without_a_newline
    assert_equal [:SCONST, :SCONST], types("'a' 'b'")
  end

  def test_string_continuation_allows_comments
    assert_equal ["ab"], values("'a' -- one\n -- two\n 'b'")
  end

  def test_continued_escape_string_stays_an_escape_string
    # The second segment is still E'...', so \' does not end it.
    assert_equal [:SELECT, :SCONST, ",", :ICONST], types("SELECT E'a'\n'b\\' , danger() , ', 1")
  end

  def test_continued_plain_string_stays_plain
    assert_equal [:SCONST, ",", :IDENT], types("'a'\n'b\\' , x")
  end

  def test_unicode_string
    token = tokens("U&'d\\0061t\\+000061'")[0]
    assert_equal :SCONST, token.type
    assert_equal "data", token.value
  end

  # --- Unicode-escaped identifiers ---

  def test_unicode_identifier_is_decoded
    token = tokens('U&"\\0073ecrets"')[0]
    assert_equal :IDENT, token.type
    assert_equal "secrets", token.value
  end

  def test_unicode_identifier_with_uescape
    assert_equal [:IDENT], types(%q{U&"!0073ecrets" UESCAPE '!'})
    assert_equal ["secrets"], values(%q{U&"!0073ecrets" UESCAPE '!'})
  end

  def test_unicode_identifier_doubled_escape_and_surrogate_pair
    assert_equal ["a\\b"], values('U&"a\\\\b"')
    assert_equal ["\u{1F600}"], values('U&"\\D83D\\DE00"')
  end

  def test_invalid_unicode_escapes
    assert_lex_error('U&"\\00"', /invalid Unicode escape/)
    assert_lex_error('U&"\\DE00"', /surrogate/)
    assert_lex_error('U&"\\D83Dx"', /surrogate/)
    assert_lex_error('U&"\\0000"', /invalid Unicode escape value/)
    assert_lex_error(%q{U&"a" UESCAPE '+'}, /invalid Unicode escape character/)
    assert_lex_error('U&"a" UESCAPE x', /UESCAPE must be followed/)
  end

  def test_u_ampersand_without_quote_is_an_identifier_and_operator
    assert_equal [:IDENT, :Op, :IDENT], types("u & x")
    assert_equal [:IDENT, :Op, :IDENT], types("u&x")
  end

  # --- Dollar quoting and parameters ---

  def test_dollar_quoted_string
    assert_equal [" it's -- /* "], values("$$ it's -- /* $$")
    assert_equal [:SCONST], types("$$ it's -- /* $$")
  end

  def test_tagged_dollar_quote
    assert_equal ["a $$ b $other$ c"], values("$tag$a $$ b $other$ c$tag$")
  end

  def test_dollar_quote_with_multibyte_content
    assert_equal [:SELECT, :SCONST, ",", :IDENT], types("SELECT $$éé$$, secret")
  end

  def test_dollar_quote_tag_is_case_sensitive
    assert_lex_error("$a$ x $A$", /unterminated dollar-quoted/)
  end

  def test_unterminated_dollar_quote
    assert_lex_error("$$ abc", /unterminated dollar-quoted/)
  end

  def test_parameter
    token = tokens("$12")[0]
    assert_equal :PARAM, token.type
    assert_equal "$12", token.value
  end

  def test_parameter_followed_by_dollar_quote
    assert_equal [:PARAM, :SCONST], types("$1$$x$$")
  end

  def test_parameter_junk_and_overflow
    assert_lex_error("$1abc", /trailing junk after parameter/)
    assert_lex_error("$99999999999", /too large/)
  end

  def test_lone_dollar
    assert_lex_error("$", /unexpected character/)
    assert_lex_error("$abc", /unexpected character/)
  end

  # --- Numbers ---

  def test_integers
    assert_equal [:ICONST, :ICONST, :ICONST, :ICONST], types("0 42 1_000 2147483647")
  end

  def test_integer_too_big_for_int4_is_fconst
    assert_equal [:FCONST], types("2147483648")
  end

  def test_radix_integers
    assert_equal [:ICONST, :ICONST, :ICONST], types("0x1F 0o17 0b101")
    assert_equal [:ICONST], types("0x_1F")
  end

  def test_decimal_and_real
    assert_equal [:FCONST] * 6, types("1.5 .5 1. 1e5 1.5e-3 1.e5")
  end

  def test_integer_followed_by_dot_dot
    assert_equal [:ICONST, :DOT_DOT, :ICONST], types("1..2")
  end

  def test_numeric_junk
    ["1abc", "1e", "1e+", "1.5x", "0x", "0xg", "0b12", "1_", "1__0", "0x1g"].each do |sql|
      assert_lex_error(sql)
    end
  end

  # --- Operators and punctuation ---

  def test_self_characters
    assert_equal %w[, ( ) [ ] . ; : + - * / % ^ < > =], types(", ( ) [ ] . ; : + - * / % ^ < > =")
  end

  def test_multi_character_tokens
    assert_equal [:TYPECAST, :DOT_DOT, :COLON_EQUALS, :EQUALS_GREATER, :LESS_EQUALS,
      :GREATER_EQUALS, :NOT_EQUALS, :NOT_EQUALS], types(":: .. := => <= >= <> !=")
  end

  def test_operators
    assert_equal [:Op, :Op, :Op, :Op, :Op], types("|| ~* @> <=> !~~")
  end

  def test_operator_sheds_trailing_plus_and_minus
    assert_equal ["<", "-"], types("<-")
    assert_equal [:GREATER_EQUALS, "-"], types(">=-")
    assert_equal [:NOT_EQUALS, "+"], types("<>+")
    assert_equal ["*", "-", "-"], types("*- -")
  end

  def test_operator_keeps_trailing_minus_after_special_character
    assert_equal [:Op], types("@-")
    assert_equal ["@-"], values("@-")
    assert_equal ["!=-"], values("!=-")
  end

  def test_operator_stops_at_line_comment
    assert_equal [:ICONST, "+", :ICONST], types("1 +-- comment\n2")
  end

  def test_operator_stops_at_block_comment
    assert_equal [:ICONST, "+", :ICONST], types("1 +/* ' */ 2")
    assert_equal [:ICONST, :Op, :ICONST], types("1 ||/* c */ 2")
  end

  def test_operator_too_long
    assert_lex_error("@" * 64, /operator too long/)
    assert_equal [:Op], types("@" * 63)
  end

  def test_unexpected_characters
    ["\\", "{", "}", " "].each { |sql| tokens(sql) rescue assert_kind_of(Pgsqlarbiter::LexError, $!) }
    assert_lex_error("\\")
    assert_lex_error("{")
  end

  # --- Lookahead filter ---

  def test_not_la
    assert_equal [:NOT_LA, :IN_P], types("NOT IN")
    assert_equal [:NOT_LA, :LIKE], types("NOT /* c */ LIKE")
    assert_equal [:NOT, :NULL_P], types("NOT NULL")
  end

  def test_nulls_la
    assert_equal [:NULLS_LA, :FIRST_P], types("NULLS FIRST")
    assert_equal [:NULLS_P, :DISTINCT], types("NULLS DISTINCT")
  end

  def test_with_la
    assert_equal [:WITH_LA, :TIME], types("WITH TIME")
    assert_equal [:WITH_LA, :ORDINALITY], types("WITH ORDINALITY")
    assert_equal [:WITHOUT_LA, :TIME], types("WITHOUT TIME")
    assert_equal [:WITH, :IDENT], types("WITH x")
  end

  def test_format_la
    assert_equal [:FORMAT_LA, :JSON], types("FORMAT JSON")
    assert_equal [:FORMAT, :IDENT], types("FORMAT x")
  end

  # --- Input validation ---

  def test_invalid_utf8_is_a_lex_error
    assert_lex_error("SELECT '\xff'", /valid UTF-8/)
  end

  def test_other_encodings_are_rejected
    assert_lex_error("SELECT 1".encode("UTF-16LE"), /valid UTF-8/)
    assert_lex_error("SELECT '\xe9'".dup.force_encoding("ISO-8859-1"), /valid UTF-8/)
  end

  def test_nul_byte_is_rejected
    assert_lex_error("SELECT 1\0", /NUL/)
  end

  def test_non_string_is_rejected
    assert_lex_error(nil, /String/)
  end

  # --- Positions ---

  def test_positions_are_byte_offsets
    toks = tokens("SELECT 'é', x")
    assert_equal [0, 7, 11, 13], toks.map(&:position)
  end
end
