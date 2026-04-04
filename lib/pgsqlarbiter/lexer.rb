# frozen_string_literal: true

require "strscan"

module Pgsqlarbiter
  # SQL lexer that converts a query string into an array of {Token} objects.
  #
  # Handles all PostgreSQL token types including keywords, identifiers (plain and
  # double-quoted), strings (single-quoted, dollar-quoted, and prefixed), numbers,
  # parameters, operators, and punctuation.
  class Lexer
    include TokenType

    # Tokenize a SQL query string.
    #
    # @param sql [String] the SQL string to tokenize
    # @return [Array<Token>] list of tokens ending with an EOF token
    # @raise [LexError] on invalid syntax such as unexpected characters or unterminated
    #   strings/comments
    def tokenize(sql)
      @scanner = StringScanner.new(sql)
      @tokens = []

      until @scanner.eos?
        scan_token
      end

      @tokens << Token.new(type: EOF, value: nil, position: @scanner.pos)
      @tokens
    end

    private

    def scan_token
      pos = @scanner.pos

      # 1. Whitespace — skip
      return if @scanner.skip(/\s+/)

      # 2. Line comment — skip
      return if @scanner.skip(/--[^\n]*/)

      # 3. Block comment — skip (handle nesting)
      if @scanner.scan(/\/\*/)
        scan_block_comment(pos)
        return
      end

      # 4. Dollar-quoted string
      if @scanner.check(/\$([\p{L}_][\p{L}\d_]*)?\$/)
        scan_dollar_string(pos)
        return
      end

      # 5. Parameter placeholder ($1, $2, ...)
      if (m = @scanner.scan(/\$\d+/))
        @tokens << Token.new(type: PARAM, value: m, position: pos)
        return
      end

      # 6. Single-quoted strings (including E'', B'', X'', N'' prefixes)
      # Prefix detection is handled in the identifier branch (step 12)
      if @scanner.check(/'/)
        scan_single_quoted_string(pos, prefix: nil)
        return
      end

      # 7. Double-quoted identifier
      if @scanner.check(/"/)
        scan_quoted_identifier(pos, unicode: false)
        return
      end

      # 8. Numbers
      if (m = @scanner.scan(/0[xX][0-9a-fA-F_]+/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/0[oO][0-7_]+/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/0[bB][01_]+/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/\d[\d_]*\.[\d_]+(?:[eE][+-]?\d[\d_]*)?/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/\d[\d_]*[eE][+-]?\d[\d_]*/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/\d[\d_]*/))
        # Check this isn't followed by dot+digits (which would be a decimal)
        if @scanner.check(/\.[\d_]/)
          m += @scanner.scan(/\.[\d_]+(?:[eE][+-]?\d[\d_]*)?/)
        end
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end
      if (m = @scanner.scan(/\.[\d_]+(?:[eE][+-]?\d[\d_]*)?/))
        @tokens << Token.new(type: NUMBER, value: m, position: pos)
        return
      end

      # 9. Typecast ::
      if @scanner.scan(/::/)
        @tokens << Token.new(type: TYPECAST, value: "::", position: pos)
        return
      end

      # 10. Single-char punctuation
      ch = @scanner.peek(1)
      case ch
      when "("
        @scanner.getch
        @tokens << Token.new(type: LPAREN, value: "(", position: pos)
        return
      when ")"
        @scanner.getch
        @tokens << Token.new(type: RPAREN, value: ")", position: pos)
        return
      when "["
        @scanner.getch
        @tokens << Token.new(type: LBRACKET, value: "[", position: pos)
        return
      when "]"
        @scanner.getch
        @tokens << Token.new(type: RBRACKET, value: "]", position: pos)
        return
      when ","
        @scanner.getch
        @tokens << Token.new(type: COMMA, value: ",", position: pos)
        return
      when ";"
        @scanner.getch
        @tokens << Token.new(type: SEMICOLON, value: ";", position: pos)
        return
      when "*"
        @scanner.getch
        @tokens << Token.new(type: STAR, value: "*", position: pos)
        return
      when "."
        @scanner.getch
        @tokens << Token.new(type: DOT, value: ".", position: pos)
        return
      end

      # 11. Multi-char operators
      if (m = @scanner.scan(%r{[+\-/<>=~!@#%^&|`?]+}))
        @tokens << Token.new(type: OP, value: m, position: pos)
        return
      end

      # 12. Unquoted identifier / keyword (with string prefix detection)
      if (m = @scanner.scan(/[\p{L}_][\p{L}\d_]*/))
        lower = m.downcase

        # Check for U& prefix for unicode strings/identifiers
        if lower == "u" && @scanner.check(/&['"]/i)
          @scanner.scan(/&/)
          if @scanner.check(/'/)
            scan_single_quoted_string(pos, prefix: "U&")
          else
            scan_quoted_identifier(pos, unicode: true)
          end
          return
        end

        # Check for string prefixes: E, B, X, N immediately followed by '
        if %w[e b x n].include?(lower) && @scanner.check(/'/)
          scan_single_quoted_string(pos, prefix: lower)
          return
        end

        upper = m.upcase
        if Keywords::ALL.include?(upper)
          @tokens << Token.new(type: KEYWORD, value: upper, position: pos)
        else
          @tokens << Token.new(type: IDENT, value: lower, position: pos)
        end
        return
      end

      # 13. Single colon (not part of ::)
      if @scanner.scan(/:/)
        @tokens << Token.new(type: OP, value: ":", position: pos)
        return
      end

      raise LexError, "unexpected character #{@scanner.peek(1).inspect} at position #{pos}"
    end

    def scan_block_comment(start_pos)
      depth = 1
      until @scanner.eos?
        if @scanner.scan(/\/\*/)
          depth += 1
        elsif @scanner.scan(/\*\//)
          depth -= 1
          return if depth == 0
        else
          @scanner.getch
        end
      end
      raise LexError, "unterminated block comment starting at position #{start_pos}"
    end

    def scan_dollar_string(start_pos)
      @scanner.scan(/\$([\p{L}_][\p{L}\d_]*)?\$/)
      tag = @scanner.matched
      content = +""
      until @scanner.eos?
        idx = @scanner.rest.index(tag)
        if idx
          content << @scanner.rest[0, idx]
          @scanner.pos += idx + tag.length
          @tokens << Token.new(type: STRING, value: content, position: start_pos)
          return
        else
          content << @scanner.rest
          @scanner.terminate
        end
      end
      raise LexError, "unterminated dollar-quoted string starting at position #{start_pos}"
    end

    def scan_single_quoted_string(start_pos, prefix:)
      @scanner.scan(/'/)
      escape_mode = (prefix == "e") # E-strings support backslash escapes
      content = +""

      until @scanner.eos?
        if escape_mode && @scanner.scan(/\\/)
          if @scanner.eos?
            raise LexError, "unterminated string starting at position #{start_pos}"
          end
          content << "\\" << @scanner.getch
        elsif @scanner.scan(/''/)
          content << "''"
        elsif @scanner.scan(/'/)
          @tokens << Token.new(type: STRING, value: content, position: start_pos)
          return
        else
          content << @scanner.getch
        end
      end

      raise LexError, "unterminated string starting at position #{start_pos}"
    end

    def scan_quoted_identifier(start_pos, unicode:)
      @scanner.scan(/"/)
      content = +""

      until @scanner.eos?
        if @scanner.scan(/""/)
          content << '"'
        elsif @scanner.scan(/"/)
          @tokens << Token.new(type: QUOTED_IDENT, value: content, position: start_pos)
          return
        else
          content << @scanner.getch
        end
      end

      raise LexError, "unterminated quoted identifier starting at position #{start_pos}"
    end
  end
end
