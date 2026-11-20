# frozen_string_literal: true

require "strscan"

module Pgsqlarbiter
  # SQL lexer. A rule-for-rule port of PostgreSQL's scanner
  # (src/backend/parser/scan.l) and of the token filter that sits between the
  # scanner and the grammar (base_yylex in src/backend/parser/parser.c).
  #
  # Token boundaries must match PostgreSQL's exactly: any disagreement lets SQL
  # hide from the analyzer. Where PostgreSQL's behaviour depends on server
  # settings, the lexer assumes the defaults and documents it here:
  #
  # * +standard_conforming_strings+ is +on+ (backslashes are ordinary characters
  #   in plain string literals).
  # * The client and server encodings are UTF-8.
  #
  # Unquoted identifiers containing non-ASCII upper-case letters are rejected.
  # PostgreSQL folds those differently depending on the server encoding, so
  # their meaning cannot be known here. Quoting the identifier removes the
  # ambiguity.
  class Lexer
    # Maximum identifier length in bytes (NAMEDATALEN - 1). PostgreSQL silently
    # truncates longer identifiers.
    MAX_IDENTIFIER_BYTES = 63

    NON_ASCII = '\u0080-\u{10FFFF}'
    SPACE = /[ \t\n\r\f\v]+/
    LINE_COMMENT = /--[^\n\r]*/
    BLOCK_COMMENT_DELIMITER = %r{/\*|\*/}
    IDENTIFIER = /[A-Za-z_#{NON_ASCII}][A-Za-z_0-9$#{NON_ASCII}]*/
    IDENTIFIER_START = /[A-Za-z_#{NON_ASCII}]/
    DOLLAR_DELIMITER = /\$(?:[A-Za-z_#{NON_ASCII}][A-Za-z_0-9#{NON_ASCII}]*)?\$/
    PARAM = /\$[0-9]+/
    DECIMAL = /[0-9](?:_?[0-9])*/
    RADIX_INTEGER = /0[xX](?:_?[0-9A-Fa-f])+|0[oO](?:_?[0-7])+|0[bB](?:_?[01])+/
    # numeric, real and decinteger. "1..2" is the integer 1 followed by "..".
    NUMBER = /(?:#{DECIMAL}\.(?!\.)(?:#{DECIMAL})?|\.#{DECIMAL}|#{DECIMAL})(?:[eE][-+]?#{DECIMAL})?/
    DECIMAL_INTEGER = /\A#{DECIMAL}\z/
    OPERATOR = %r{[~!@#^&|`?+\-*/%<>=]+}
    OPERATOR_COMMENT_START = %r{/\*|--}
    SELF_CHARS = ",()[].;:+-*/%^<>="
    TWO_CHAR_OPERATORS = {
      "=>" => :EQUALS_GREATER, ">=" => :GREATER_EQUALS, "<=" => :LESS_EQUALS,
      "<>" => :NOT_EQUALS, "!=" => :NOT_EQUALS
    }.freeze
    # After a closing quote, whitespace containing a newline followed by another
    # quote continues the same literal (quotecontinue in scan.l). Comments are
    # allowed in that whitespace. Atomic groups keep this linear.
    QUOTE_CONTINUE = /(?>(?:[ \t\f\v]|--[^\n\r]*)*)[\n\r](?>(?:[ \t\n\r\f\v]|--[^\n\r]*[\n\r])*)'/
    INT32_MAX = 2_147_483_647

    # Tokenize a SQL string.
    #
    # @param sql [String] the SQL to tokenize; must be valid UTF-8
    # @return [Array<Token>] tokens in source order, as the grammar expects them
    # @raise [LexError] on anything PostgreSQL's scanner would reject, and on
    #   input whose meaning depends on server configuration
    def tokenize(sql)
      raise LexError, "SQL must be a String" unless sql.is_a?(String)
      unless (sql.encoding == Encoding::UTF_8 || sql.encoding == Encoding::US_ASCII) && sql.valid_encoding?
        raise LexError, "SQL must be valid UTF-8"
      end
      raise LexError, "SQL must not contain NUL bytes" if sql.include?("\0")

      @s = StringScanner.new(sql)
      @tokens = []
      scan_token until @s.eos?
      apply_lookahead_filter(@tokens)
    end

    private

    def emit(type, value, position)
      @tokens << Token.new(type: type, value: value, position: position)
    end

    def scan_token
      s = @s
      return if s.skip(SPACE)
      return if s.skip(LINE_COMMENT)

      pos = s.pos
      return skip_block_comment(pos) if s.skip(%r{/\*})

      if (text = s.scan(IDENTIFIER))
        scan_identifier(text, pos)
      elsif s.match?(/'/)
        emit(:SCONST, scan_quoted(:xq, pos), pos)
      elsif s.match?(/"/)
        emit(:IDENT, truncate_identifier(scan_double_quoted(pos)), pos)
      elsif (delimiter = s.scan(DOLLAR_DELIMITER))
        finish = s.string.byteindex(delimiter, s.pos)
        raise LexError, "unterminated dollar-quoted string at position #{pos}" unless finish
        emit(:SCONST, s.string.byteslice(s.pos, finish - s.pos), pos)
        s.pos = finish + delimiter.bytesize
      elsif (text = s.scan(PARAM))
        raise LexError, "trailing junk after parameter at position #{pos}" if s.match?(IDENTIFIER_START)
        raise LexError, "parameter number too large at position #{pos}" if text[1..].to_i > INT32_MAX
        emit(:PARAM, text, pos)
      elsif (text = s.scan(RADIX_INTEGER))
        # A following digit or letter would make scan.l's integer_junk rule the
        # longest match.
        raise LexError, "trailing junk after numeric literal at position #{pos}" if s.match?(/[0-9]|#{IDENTIFIER_START}/)
        base = {"x" => 16, "o" => 8, "b" => 2}.fetch(text[1].downcase)
        emit(text[2..].delete("_").to_i(base) <= INT32_MAX ? :ICONST : :FCONST, text, pos)
      elsif (text = s.scan(NUMBER))
        raise LexError, "trailing junk after numeric literal at position #{pos}" if s.match?(IDENTIFIER_START)
        integer = DECIMAL_INTEGER.match?(text) && text.delete("_").to_i <= INT32_MAX
        emit(integer ? :ICONST : :FCONST, text, pos)
      elsif s.skip(/::/) then emit(:TYPECAST, "::", pos)
      elsif s.skip(/\.\./) then emit(:DOT_DOT, "..", pos)
      elsif s.skip(/:=/) then emit(:COLON_EQUALS, ":=", pos)
      elsif (text = s.check(OPERATOR))
        scan_operator(text, pos)
      elsif (text = s.scan(/[,()\[\].;:]/))
        emit(text, text, pos)
      else
        raise LexError, "unexpected character #{s.peek(1).inspect} at position #{pos}"
      end
    end

    # Block comments nest. The opening delimiter has already been consumed.
    def skip_block_comment(pos)
      depth = 1
      while depth > 0
        raise LexError, "unterminated /* comment at position #{pos}" unless @s.skip_until(BLOCK_COMMENT_DELIMITER)
        depth += (@s.matched == "/*") ? 1 : -1
      end
    end

    def scan_identifier(text, pos)
      s = @s
      if text.bytesize == 1
        if s.match?(/'/)
          case text
          when "e", "E" then return emit(:SCONST, scan_quoted(:xe, pos), pos)
          when "b", "B" then return emit(:BCONST, scan_quoted(:xb, pos), pos)
          when "x", "X" then return emit(:XCONST, scan_quoted(:xh, pos), pos)
          when "n", "N"
            # N'...' is the keyword NCHAR followed by an ordinary string.
            return emit(:NCHAR, "nchar", pos)
          end
        elsif (text == "u" || text == "U") && s.match?(/&['"]/)
          s.skip(/&/)
          if s.match?(/'/)
            return emit(:USCONST, scan_quoted(:xus, pos), pos)
          else
            return emit(:UIDENT, scan_double_quoted(pos), pos)
          end
        end
      end

      folded = text.downcase(:ascii)
      if (keyword = Keywords::TOKENS[folded])
        return emit(keyword, folded, pos)
      end

      if !folded.ascii_only? && folded != folded.downcase
        raise LexError, "unquoted identifier #{text.inspect} at position #{pos} contains non-ASCII " \
                        "upper-case letters, which PostgreSQL folds differently depending on the " \
                        "server encoding; quote the identifier"
      end
      emit(:IDENT, truncate_identifier(folded), pos)
    end

    # Scan a quoted literal starting at its opening quote. +mode+ is the scan.l
    # start condition: :xq (plain), :xe (E''), :xus (U&''), :xb (B'') or :xh (X'').
    def scan_quoted(mode, pos)
      s = @s
      s.skip(/'/)
      value = +""
      loop do
        case mode
        when :xe
          if (chunk = s.scan(/[^\\']+/)) then value << chunk
          elsif s.skip(/''/) then value << "'"
          elsif s.skip(/\\/)
            # A backslash always consumes the next character, including a quote.
            # Multi-character escapes (\ooo, \xhh, \uXXXX) never contain a quote,
            # so consuming one character keeps the literal's extent exact.
            escaped = s.getch
            raise LexError, "unterminated quoted string at position #{pos}" unless escaped
            value << "\\" << escaped
          end
        when :xq, :xus
          if (chunk = s.scan(/[^']+/)) then value << chunk
          elsif s.skip(/''/) then value << "'"
          end
        else # :xb, :xh have no escapes at all
          chunk = s.scan(/[^']*/)
          value << chunk
        end

        next unless s.match?(/'/) || s.eos?
        raise LexError, "unterminated quoted string at position #{pos}" if s.eos?
        next if mode != :xb && mode != :xh && s.match?(/''/)

        s.skip(/'/)
        return value unless s.skip(QUOTE_CONTINUE)
      end
    end

    # Scan a double-quoted identifier starting at its opening quote.
    def scan_double_quoted(pos)
      s = @s
      s.skip(/"/)
      value = +""
      loop do
        if (chunk = s.scan(/[^"]+/)) then value << chunk
        elsif s.skip(/""/) then value << '"'
        elsif s.skip(/"/) then break
        else raise LexError, "unterminated quoted identifier at position #{pos}"
        end
      end
      raise LexError, "zero-length delimited identifier at position #{pos}" if value.empty?
      value
    end

    # The {operator} rule of scan.l, including its three special cases: an
    # operator stops before an embedded comment start, sheds trailing + and -
    # unless it contains one of ~!@#^&|`?%, and a result that is a single
    # "self" character or a known two-character operator is that token.
    def scan_operator(text, pos)
      length = text.length
      comment = text.index(OPERATOR_COMMENT_START)
      length = comment if comment

      if length > 1 && (text[length - 1] == "+" || text[length - 1] == "-")
        unless text[0, length - 1].match?(/[~!@#^&|`?%]/)
          length -= 1
          length -= 1 while length > 1 && (text[length - 1] == "+" || text[length - 1] == "-")
        end
      end

      text = text[0, length]
      @s.pos += length # operator characters are all single-byte
      if length == 1 && SELF_CHARS.include?(text)
        emit(text, text, pos)
      elsif length == 2 && (type = TWO_CHAR_OPERATORS[text])
        emit(type, text, pos)
      else
        raise LexError, "operator too long at position #{pos}" if length > MAX_IDENTIFIER_BYTES
        emit(:Op, text, pos)
      end
    end

    def truncate_identifier(name)
      return name if name.bytesize <= MAX_IDENTIFIER_BYTES

      name = name.byteslice(0, MAX_IDENTIFIER_BYTES)
      name = name.byteslice(0, name.bytesize - 1) until name.valid_encoding?
      name
    end

    # base_yylex: the grammar needs one token of lookahead in a few places, and
    # U& literals are converted to ordinary ones here.
    def apply_lookahead_filter(tokens)
      out = []
      i = 0
      while i < tokens.length
        token = tokens[i]
        following = tokens[i + 1]&.type
        i += 1
        case token.type
        when :FORMAT
          token = token.with(type: :FORMAT_LA) if following == :JSON
        when :NOT
          if following == :BETWEEN || following == :IN_P || following == :LIKE ||
              following == :ILIKE || following == :SIMILAR
            token = token.with(type: :NOT_LA)
          end
        when :NULLS_P
          token = token.with(type: :NULLS_LA) if following == :FIRST_P || following == :LAST_P
        when :WITH
          token = token.with(type: :WITH_LA) if following == :TIME || following == :ORDINALITY
        when :WITHOUT
          token = token.with(type: :WITHOUT_LA) if following == :TIME
        when :UIDENT, :USCONST
          escape = "\\"
          if following == :UESCAPE
            literal = tokens[i + 1]
            unless literal && literal.type == :SCONST
              raise LexError, "UESCAPE must be followed by a simple string literal at position #{token.position}"
            end
            escape = literal.value
            unless escape.bytesize == 1 && !escape.match?(/[0-9A-Fa-f+'" \t\n\r\f\v]/)
              raise LexError, "invalid Unicode escape character at position #{literal.position}"
            end
            i += 2
          end
          value = decode_unicode_escapes(token.value, escape, token.position)
          token = if token.type == :UIDENT
            token.with(type: :IDENT, value: truncate_identifier(value))
          else
            token.with(type: :SCONST, value: value)
          end
        end
        out << token
      end
      out
    end

    # str_udeescape: decode \XXXX and \+XXXXXX escapes, with UTF-16 surrogate pairs.
    def decode_unicode_escapes(text, escape, pos)
      out = +""
      pair_first = nil
      chars = text.chars
      i = 0
      invalid_pair = -> { raise LexError, "invalid Unicode surrogate pair at position #{pos}" }
      while i < chars.length
        if chars[i] != escape
          invalid_pair.call if pair_first
          out << chars[i]
          i += 1
          next
        end

        if chars[i + 1] == escape
          invalid_pair.call if pair_first
          out << escape
          i += 2
          next
        end

        digits, width =
          if chars[i + 1] == "+"
            [chars[i + 2, 6], 8]
          else
            [chars[i + 1, 4], 5]
          end
        expected = width - (width == 8 ? 2 : 1)
        unless digits && digits.length == expected && digits.all? { |c| c.match?(/\A[0-9A-Fa-f]\z/) }
          raise LexError, "invalid Unicode escape at position #{pos}"
        end
        code = digits.join.to_i(16)
        raise LexError, "invalid Unicode escape value at position #{pos}" unless code > 0 && code <= 0x10FFFF

        if pair_first
          invalid_pair.call unless code.between?(0xDC00, 0xDFFF)
          code = ((pair_first & 0x3FF) << 10) + 0x10000 + (code & 0x3FF)
          pair_first = nil
        elsif code.between?(0xDC00, 0xDFFF)
          invalid_pair.call
        end

        if code.between?(0xD800, 0xDBFF)
          pair_first = code
        else
          out << [code].pack("U")
        end
        i += width
      end
      invalid_pair.call if pair_first
      raise LexError, "zero-length delimited identifier at position #{pos}" if out.empty? && !text.empty?
      out
    end
  end
end
