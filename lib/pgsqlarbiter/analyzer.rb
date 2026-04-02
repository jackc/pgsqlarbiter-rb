# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  class Analyzer
    include TokenType

    JOIN_PREFIXES = Set["INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL"].freeze
    FUNCTIONS_WITH_FROM_SYNTAX = Set["EXTRACT", "TRIM", "SUBSTRING"].freeze

    def analyze(sql)
      @tokens = Lexer.new.tokenize(sql)
      @pos = 0
      @paren_depth = 0
      @tables = Set.new
      @functions = Set.new
      @cte_names = Set.new
      @suppress_from_depths = []

      reject_multiple_statements!
      stmt_type = determine_statement_type!

      @pos = 0
      @paren_depth = 0
      pre_collect_cte_names!

      @pos = 0
      @paren_depth = 0
      walk!

      Result.new(
        statement_type: stmt_type,
        tables: @tables.to_a.sort,
        functions: @functions.to_a.sort
      )
    end

    private

    # --- Token access helpers ---

    def current
      @tokens[@pos]
    end

    def peek
      @tokens[@pos + 1]
    end

    def advance
      @pos += 1
    end

    def at_end?
      current.type == EOF
    end

    def keyword?(value)
      current.type == KEYWORD && current.value == value
    end

    def keyword_one_of?(*values)
      current.type == KEYWORD && values.include?(current.value)
    end

    def ident_or_quoted?
      current.type == IDENT || current.type == QUOTED_IDENT
    end

    def can_be_name?
      ident_or_quoted? || (current.type == KEYWORD && !clause_keyword?(current.value))
    end

    def identifier_value(token)
      case token.type
      when IDENT then token.value
      when QUOTED_IDENT
        if token.value.include?(".")
          raise ParseError,
            "quoted identifier containing a dot is not supported: \"#{token.value}\""
        end
        token.value
      when KEYWORD then token.value.downcase
      else token.value.to_s
      end
    end

    # --- Phase 1: Reject multiple statements ---

    def reject_multiple_statements!
      @tokens.each_with_index do |token, i|
        if token.type == SEMICOLON
          rest = @tokens[(i + 1)..]
          if rest.any? { |t| t.type != EOF && t.type != SEMICOLON }
            raise MultipleStatementsError, "multiple statements are not allowed"
          end
        end
      end
    end

    # --- Phase 2: Determine statement type ---

    def determine_statement_type!
      raise ParseError, "empty query" if at_end?
      raise DisallowedStatementError, "expected a SQL statement, got #{current.value.inspect}" unless current.type == KEYWORD

      case current.value
      when "SELECT" then :select
      when "INSERT" then :insert
      when "UPDATE" then :update
      when "DELETE" then :delete
      when "MERGE"  then :merge
      when "VALUES" then :values
      when "WITH"   then determine_cte_statement_type!
      else
        raise DisallowedStatementError, "#{current.value} statements are not allowed"
      end
    end

    def determine_cte_statement_type!
      depth = 0
      advance # past WITH
      advance if keyword?("RECURSIVE")

      loop do
        break if at_end?
        case current.type
        when LPAREN then depth += 1; advance
        when RPAREN then depth -= 1; advance
        when KEYWORD
          if depth == 0
            case current.value
            when "SELECT" then return :select
            when "INSERT" then return :insert
            when "UPDATE" then return :update
            when "DELETE" then return :delete
            when "MERGE"  then return :merge
            when "VALUES" then return :values
            else advance
            end
          else
            advance
          end
        else
          advance
        end
      end

      raise ParseError, "could not determine statement type in WITH clause"
    end

    # --- Phase 3: Pre-collect CTE names (index-based, no @pos modification) ---

    def pre_collect_cte_names!
      collect_cte_names_in_range!(0, @tokens.length)
    end

    def collect_cte_names_in_range!(from, to)
      i = from
      while i < to
        if @tokens[i].type == KEYWORD && @tokens[i].value == "WITH"
          i += 1
          i += 1 if i < to && @tokens[i]&.type == KEYWORD && @tokens[i]&.value == "RECURSIVE"
          loop do
            break unless i < to && (@tokens[i].type == IDENT || @tokens[i].type == QUOTED_IDENT)
            @cte_names << identifier_value(@tokens[i])
            i += 1
            # Skip optional column list
            if i < to && @tokens[i]&.type == LPAREN
              depth = 1; i += 1
              while depth > 0 && i < to
                depth += 1 if @tokens[i].type == LPAREN
                depth -= 1 if @tokens[i].type == RPAREN
                i += 1
              end
            end
            # Skip AS [NOT] MATERIALIZED
            if i < to && @tokens[i]&.type == KEYWORD && @tokens[i]&.value == "AS"
              i += 1
              if i < to && @tokens[i]&.type == KEYWORD && @tokens[i]&.value == "NOT"
                i += 1
                i += 1 if i < to && @tokens[i]&.type == KEYWORD && @tokens[i]&.value == "MATERIALIZED"
              elsif i < to && @tokens[i]&.type == KEYWORD && @tokens[i]&.value == "MATERIALIZED"
                i += 1
              end
              # Recurse into CTE body for nested WITH clauses, then skip it
              if i < to && @tokens[i]&.type == LPAREN
                body_start = i + 1
                depth = 1; i += 1
                while depth > 0 && i < to
                  depth += 1 if @tokens[i].type == LPAREN
                  depth -= 1 if @tokens[i].type == RPAREN
                  i += 1
                end
                collect_cte_names_in_range!(body_start, i - 1)
              end
            end
            if i < to && @tokens[i]&.type == COMMA
              i += 1
            else
              break
            end
          end
        else
          i += 1
        end
      end
    end

    # --- Phase 4: Main walk ---

    def walk!
      while !at_end?
        dispatch_token!
      end
    end

    def dispatch_token!
      case current.type
      when KEYWORD  then handle_keyword!
      when IDENT    then maybe_extract_function_call!
      when QUOTED_IDENT then maybe_extract_quoted_function_call!
      when LPAREN   then @paren_depth += 1; advance
      when RPAREN   then handle_rparen!
      else advance
      end
    end

    def handle_rparen!
      if !@suppress_from_depths.empty? && @paren_depth == @suppress_from_depths.last + 1
        @suppress_from_depths.pop
      end
      @paren_depth -= 1
      advance
    end

    def suppress_from?
      !@suppress_from_depths.empty? && @paren_depth > @suppress_from_depths.last
    end

    def handle_keyword!
      val = current.value
      case val
      when "FROM"
        if suppress_from?
          advance
        else
          advance
          extract_from_list!
        end
      when "JOIN"
        advance
        extract_single_from_item!
      when "INNER"
        advance
        if keyword?("JOIN")
          advance
          extract_single_from_item!
        end
      when "LEFT", "RIGHT", "FULL"
        advance
        advance if keyword?("OUTER")
        if keyword?("JOIN")
          advance
          extract_single_from_item!
        end
      when "CROSS"
        advance
        if keyword?("JOIN")
          advance
          extract_single_from_item!
        end
      when "NATURAL"
        advance
        if keyword_one_of?("LEFT", "RIGHT", "FULL", "INNER")
          advance
          advance if keyword?("OUTER")
        end
        if keyword?("JOIN")
          advance
          extract_single_from_item!
        end
      when "INTO"
        advance
        read_table_ref! if can_be_name?
      when "UPDATE"
        advance
        advance if keyword?("ONLY")
        read_table_ref! if can_be_name?
      when "USING"
        advance
        # USING (col_list) after JOIN starts with LPAREN — skip
        # USING table after DELETE/MERGE — extract
        if can_be_name? && current.type != LPAREN
          extract_single_from_item!
        end
      else
        if FUNCTIONS_WITH_FROM_SYNTAX.include?(val) && peek&.type == LPAREN
          @functions << val.downcase
          @suppress_from_depths.push(@paren_depth)
          advance # past keyword; main loop handles LPAREN
        elsif Keywords::FUNCTION_KEYWORDS.include?(val) && peek&.type == LPAREN
          @functions << val.downcase
          advance
        else
          advance
        end
      end
    end

    # --- Function call detection ---

    def maybe_extract_function_call!
      if peek&.type == LPAREN
        name = identifier_value(current)
        @functions << name
        advance
      elsif peek&.type == DOT
        name1 = identifier_value(current)
        advance # past ident
        advance # past dot
        if (ident_or_quoted? || current.type == KEYWORD) && peek&.type == LPAREN
          name2 = identifier_value(current)
          @functions << "#{name1}.#{name2}"
          advance
        end
      else
        advance
      end
    end

    def maybe_extract_quoted_function_call!
      if peek&.type == LPAREN
        name = identifier_value(current)
        @functions << name
        advance
      elsif peek&.type == DOT
        name1 = identifier_value(current)
        advance # past quoted ident
        advance # past dot
        if (ident_or_quoted? || current.type == KEYWORD) && peek&.type == LPAREN
          name2 = identifier_value(current)
          @functions << "#{name1}.#{name2}"
          advance
        end
      else
        advance
      end
    end

    # --- FROM list extraction ---

    def extract_from_list!
      loop do
        break if at_end?
        break if should_end_from_list?

        extract_from_item!

        if current.type == COMMA
          advance
        else
          break
        end
      end
    end

    def should_end_from_list?
      return true if current.type == RPAREN
      return true if current.type == SEMICOLON
      return true if current.type == EOF
      if current.type == KEYWORD
        v = current.value
        return true if %w[WHERE GROUP HAVING ORDER LIMIT OFFSET FETCH
                          UNION INTERSECT EXCEPT WINDOW FOR RETURNING
                          ON SET WHEN].include?(v)
        return true if v == "JOIN"
        return true if JOIN_PREFIXES.include?(v) && has_join_ahead?
      end
      false
    end

    def has_join_ahead?
      i = @pos + 1
      while i < @tokens.length && i <= @pos + 3
        return true if @tokens[i].type == KEYWORD && @tokens[i].value == "JOIN"
        return false unless @tokens[i].type == KEYWORD && %w[OUTER INNER].include?(@tokens[i].value)
        i += 1
      end
      false
    end

    def extract_single_from_item!
      extract_from_item!
    end

    def extract_from_item!
      advance if keyword?("LATERAL")
      advance if keyword?("ONLY")

      if current.type == LPAREN
        # Subquery or parenthesized expression — walk inside for refs
        walk_balanced_group!
        skip_alias!
        return
      end

      return if at_end?
      return unless can_be_name?

      name = read_qualified_name!

      if current.type == LPAREN
        # Table-valued function in FROM
        @functions << name unless @cte_names.include?(name)
        walk_balanced_group! # walk function args for nested refs
        skip_alias!
      else
        @tables << name unless @cte_names.include?(name)
        skip_alias!
      end
    end

    # Walk tokens inside balanced parens, extracting refs. Consumes through closing RPAREN.
    def walk_balanced_group!
      return unless current.type == LPAREN
      start_depth = @paren_depth
      @paren_depth += 1
      advance # past LPAREN

      while !at_end? && @paren_depth > start_depth
        dispatch_token!
      end
    end

    # --- Table reference reading ---

    def read_table_ref!
      return if at_end?
      return unless can_be_name?

      name = read_qualified_name!
      @tables << name unless @cte_names.include?(name)
      skip_alias!
    end

    def read_qualified_name!
      part1 = identifier_value(current)
      advance

      if current.type == DOT && peek && (peek.type == IDENT || peek.type == QUOTED_IDENT || peek.type == KEYWORD)
        advance # past dot
        part2 = identifier_value(current)
        advance
        if current.type == DOT && peek && (peek.type == IDENT || peek.type == QUOTED_IDENT)
          advance # past dot
          part3 = identifier_value(current)
          advance
          "#{part1}.#{part2}.#{part3}"
        else
          "#{part1}.#{part2}"
        end
      else
        part1
      end
    end

    # --- Alias skipping ---

    def skip_alias!
      return if at_end?

      if keyword?("AS")
        advance
        if ident_or_quoted? || (current.type == KEYWORD && !clause_keyword?(current.value))
          advance
        end
        skip_balanced_parens! if current.type == LPAREN
      elsif ident_or_quoted?
        unless current.type == KEYWORD && clause_keyword?(current.value)
          advance
          skip_balanced_parens! if current.type == LPAREN
        end
      end
    end

    def clause_keyword?(value)
      %w[WHERE GROUP HAVING ORDER LIMIT OFFSET FETCH UNION INTERSECT EXCEPT
         JOIN INNER LEFT RIGHT FULL CROSS NATURAL ON USING
         WINDOW FOR RETURNING SET WHEN MATCHED FROM INTO].include?(value)
    end

    def skip_balanced_parens!
      return unless current.type == LPAREN
      depth = 1
      advance
      until at_end? || depth == 0
        case current.type
        when LPAREN then depth += 1
        when RPAREN then depth -= 1
        end
        advance
      end
    end
  end
end
