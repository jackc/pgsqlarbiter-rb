# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  # SQL query analyzer. Lexes the query with {Lexer}, parses it with {Parser}
  # (generated from PostgreSQL's own grammar), and walks the resulting syntax
  # tree to find every table, function and type the query refers to.
  #
  # The walk is fail-closed. Each nonterminal that carries a table, function or
  # type name has exactly one meaning in each production that uses it, and that
  # meaning is spelled out in a handler below. If the walk ever reaches such a
  # name through a production with no handler, it raises instead of guessing.
  class Analyzer
    STATEMENT_START = Set[:SELECT, :VALUES, :TABLE, :WITH, :WITH_LA, :INSERT, :UPDATE, :DELETE_P, :MERGE, "("].freeze

    STATEMENT_KINDS = {
      InsertStmt: :insert, UpdateStmt: :update, DeleteStmt: :delete, MergeStmt: :merge
    }.freeze

    # Nonterminals that are only ever labels: column names, aliases, window
    # names, collations, operator classes, named-argument names. They never
    # name a table, function or type, so the walk does not descend into them.
    LABELS = Set[
      :ColId, :ColLabel, :BareColLabel, :name, :attr_name, :param_name, :any_name,
      # FOR UPDATE OF <names> refers to FROM-clause items that are recorded where they appear.
      :qualified_name_list
    ].freeze

    # Nonterminals that carry a table, function or type name. The production
    # that contains one must have a handler that says which it is; reaching one
    # any other way is a bug in this class, and is treated as a denial.
    ROLE_BEARING = Set[:qualified_name, :func_name, :type_function_name].freeze

    # Syntax that parses but that pgsqlarbiter refuses outright.
    UNSUPPORTED = {
      any_operator: "OPERATOR() syntax",
      reloptions: "operator class parameters",
      func_type: "operator class parameters",
      cursor_name: "WHERE CURRENT OF"
    }.freeze

    NUMERIC_TYPES = {
      INT_P: "integer", INTEGER: "integer", SMALLINT: "smallint", BIGINT: "bigint",
      REAL: "real", FLOAT_P: "float", DOUBLE_P: "double precision",
      DECIMAL_P: "numeric", DEC: "numeric", NUMERIC: "numeric", BOOLEAN_P: "boolean"
    }.freeze

    # Upper bound on the work spent resolving names, so that a query built to
    # make resolution quadratic is refused instead of tying up the caller.
    WORK_LIMIT = 3_000_000

    # One query level: a SELECT, or an INSERT, UPDATE, DELETE or MERGE. It
    # holds the things its FROM clause (and target) make visible by name.
    #
    # * from_depth: how many FROM items of this level the walk is inside.
    # * on_clause: while the walk is in a join's ON condition, the index in
    #   entries where that join's members start, replaced by the names of the
    #   members once they are needed (see from_scope).
    # * in_parent_from: what from_scope was in the parent where this level
    #   starts: nil, or the names of the parent's FROM items that are
    #   certainly visible from inside this level.
    Level = Struct.new(:parent, :entries, :target, :outputs, :index, :from_depth, :on_clause, :in_parent_from)

    # Something a qualified name can refer to: a table, subquery, CTE, function
    # or join in FROM, or the target of a data-modifying statement.
    #
    # * name: the alias it is known by; nil when the name is not certain, which
    #   makes it a candidate for every qualifier; :none when it has no name.
    # * table: the table whose columns it exposes under their own names.
    # * columns: the column names it certainly has. This may be fewer than it
    #   really has, never more. nil when nothing is known, :any for a table
    #   that is missing from the schema.
    # * source: computes columns once the subquery it comes from has been walked.
    # * members: the tables underneath a join alias.
    # * pseudo: OLD, NEW and EXCLUDED.
    # * hidden: inside a join that has an alias, so not part of "*".
    Entry = Struct.new(:name, :table, :columns, :source, :members, :pseudo, :hidden)

    Cte = Struct.new(:core, :columns)

    LevelIndex = Struct.new(:any, :columns, :names, :wildcards)

    HANDLERS = {
      # statements and CTE scope
      SelectStmt: :visit_children,
      select_no_parens: :visit_statement,
      simple_select: :visit_simple_select,
      InsertStmt: :visit_statement,
      UpdateStmt: :visit_statement,
      DeleteStmt: :visit_statement,
      MergeStmt: :visit_statement,
      into_clause: :visit_into_clause,
      for_locking_clause: :visit_for_locking_clause,
      opt_on_conflict: :visit_on_conflict,
      # relations
      relation_expr: :visit_relation_expr,
      relation_expr_opt_alias: :visit_target_relation,
      insert_target: :visit_target_relation,
      joined_table: :visit_joined_table,
      # columns of the target table
      set_target: :visit_target_column,
      insert_column_item: :visit_target_column,
      index_elem: :visit_index_elem,
      insert_rest: :visit_insert_columns,
      merge_insert: :visit_insert_columns,
      # functions
      func_application: :visit_func_application,
      func_expr_common_subexpr: :visit_keyword_function,
      json_aggregate_func: :visit_keyword_function,
      xmltable: :visit_keyword_function,
      json_table: :visit_keyword_function,
      c_expr: :visit_c_expr,
      tablesample_clause: :visit_tablesample_clause,
      columnref: :visit_columnref,
      table_ref: :visit_table_ref,
      # types
      GenericType: :visit_generic_type,
      Numeric: :visit_numeric_type,
      BitWithLength: :visit_bit_type,
      BitWithoutLength: :visit_bit_type,
      character: :visit_character_type,
      ConstDatetime: :visit_datetime_type,
      ConstInterval: :visit_interval_type,
      JsonType: :visit_json_type,
      AexprConst: :visit_constant
    }.freeze

    # @param schema [Schema] the tables and columns that exist
    def initialize(schema)
      raise ArgumentError, "schema must be a Pgsqlarbiter::Schema" unless schema.is_a?(Schema)

      @schema = schema
    end

    # Analyze a SQL query string.
    #
    # @param sql [String] the SQL query to analyze
    # @return [Analysis] the statement type(s), tables, columns, functions and types
    # @raise [LexError] if the SQL cannot be tokenized
    # @raise [ParseError] if the SQL is empty or is not valid, supported syntax
    # @raise [UnresolvedNameError] if a column or table alias cannot be resolved
    # @raise [MultipleStatementsError] if the SQL contains more than one statement
    # @raise [DisallowedStatementError] if the statement is not SELECT, INSERT,
    #   UPDATE, DELETE, MERGE, or VALUES
    def analyze(sql)
      tokens = single_statement(Lexer.new.tokenize(sql))
      tree = Parser.new.parse(tokens)

      @tables = Set.new
      @functions = Set.new
      @types = Set.new
      @kinds = Set.new
      @columns = Set.new
      @cte_scopes = []
      @level = nil
      @levels = {}.compare_by_identity
      @outputs = {}.compare_by_identity
      @alias_refs = {}.compare_by_identity
      @refs = []
      @work = WORK_LIMIT
      @final = false

      statement = tree.children[0]
      statement_type = STATEMENT_KINDS[statement.name] || select_kind(statement)
      @kinds << statement_type
      walk(tree)
      @final = true
      @refs.each { |ref| resolve_ref(*ref) }

      Analysis.new(
        statement_type: statement_type,
        statement_types: @kinds.to_a.sort.freeze,
        tables: @tables.to_a.sort.freeze,
        columns: @columns.to_a.sort.freeze,
        functions: @functions.to_a.sort.freeze,
        types: @types.to_a.sort.freeze
      )
    end

    private

    # --- Statement boundaries ---

    # Return the tokens of the one statement in the input. A semicolon can never
    # appear inside a DML statement, so every semicolon separates statements.
    def single_statement(tokens)
      statements = tokens.slice_when { |a, b| a.type == ";" || b.type == ";" }
        .reject { |part| part[0].type == ";" }
      raise ParseError, "empty query" if statements.empty?
      raise MultipleStatementsError, "multiple statements are not allowed" if statements.length > 1

      statement = statements[0]
      first = statement[0]
      unless STATEMENT_START.include?(first.type)
        if Keywords::TOKENS[first.value] == first.type
          raise DisallowedStatementError, "#{first.value.upcase} statements are not allowed"
        end
        raise DisallowedStatementError, "expected a SQL statement, got #{first.value.inspect}"
      end
      statement
    end

    # :values when the statement is a bare VALUES list, otherwise :select.
    def select_kind(node)
      loop do
        case node.name
        when :SelectStmt, :select_clause then node = node.children[0]
        when :select_with_parens then node = node.children[1]
        when :select_no_parens
          node = node.children.find { |c| c.is_a?(Node) && (c.name == :simple_select || c.name == :select_clause) }
        else
          first = node.children[0]
          return (first.is_a?(Node) && first.name == :values_clause) ? :values : :select
        end
      end
    end

    # --- Tree walk ---
    #
    # Iterative, so that deeply nested or very long queries cannot overflow the
    # Ruby stack. Handlers push the nodes they want visited; the stack is LIFO,
    # so they push in reverse of the order the nodes should be visited in.

    def walk(root)
      @stack = [root]
      until @stack.empty?
        item = @stack.pop
        if item.is_a?(Node)
          name = item.name
          if (handler = HANDLERS[name])
            __send__(handler, item)
          elsif LABELS.include?(name)
            next
          elsif ROLE_BEARING.include?(name)
            raise ParseError, "unsupported syntax: #{name} in an unrecognized position"
          elsif (what = UNSUPPORTED[name])
            raise ParseError, "#{what} is not supported"
          else
            visit_children(item)
          end
        else
          item.call
        end
      end
    end

    def visit_children(node)
      node.children.reverse_each { |child| @stack << child if child.is_a?(Node) }
    end

    def visit(children)
      children.reverse_each { |child| @stack << child if child.is_a?(Node) }
    end

    # --- Statements, query levels and CTE scope ---

    # A statement that may carry a WITH clause. PostgreSQL's scoping rules:
    #
    # * The CTEs are visible in the whole statement the WITH is attached to.
    # * Without RECURSIVE, a CTE sees only the CTEs listed before it. Its own
    #   name, inside its own body, means the real table.
    # * With RECURSIVE, every CTE in the list is visible to all of them.
    #
    # The statement is also a query level for name resolution. ORDER BY, LIMIT
    # and the locking clause of a SELECT are written outside the SELECT itself
    # but belong to its level, so the level is made here and found again when
    # the walk reaches the SELECT.
    def visit_statement(node)
      kind = STATEMENT_KINDS[node.name]
      @kinds << kind if kind

      level =
        if kind
          new_level
        elsif (core = core_of(node, false))
          @levels[core] ||= new_level
        else
          # ORDER BY on a UNION, INTERSECT or EXCEPT can only name result columns.
          new_level(:any)
        end
      previous = nil
      @stack << lambda do
        finish_dml(level, node) if kind
        @level = previous
      end
      kind ? setup_dml(level, node) : mark_output_names(node)

      body = node.children
      with = body[0]
      with = with.children[0] if with.is_a?(Node) && with.name == :opt_with_clause
      if with.is_a?(Node) && with.name == :with_clause
        scope = {}
        @cte_scopes << scope
        @stack << -> { @cte_scopes.pop }
        visit(body[1..])

        recursive = with.children.any? { |c| c.is_a?(Token) && c.type == :RECURSIVE }
        ctes = flatten(with.children.last).select { |c| c.is_a?(Node) }
        # name opt_name_list AS opt_materialized '(' PreparableStmt ')' opt_search_clause opt_cycle_clause
        named = ctes.map do |cte|
          declared = cte.children[1].children[1]
          [checked(leaf(cte.children[0])), Cte.new(core_of(cte.children[5], true), declared && list_names(declared))]
        end
        named.each { |name, info| scope[name] = info } if recursive
        # A CTE body cannot see the FROM items of the statement the WITH is
        # attached to, only those of the levels around that statement.
        @stack << -> { @level = level }
        ctes.zip(named).reverse_each do |cte, (name, info)|
          @stack << -> { scope[name] = info } unless recursive
          visit(cte.children[1..])
        end
        @stack << -> { @level = level.parent }
      else
        visit(body)
      end
      @stack << lambda do
        previous = @level
        @level = level
      end
    end

    def cte(name)
      @cte_scopes.reverse_each do |scope|
        info = scope[name]
        return info if info
      end
      nil
    end

    # SELECT ..., VALUES ... and TABLE name are query levels. UNION, INTERSECT
    # and EXCEPT are not: each side is its own level.
    def visit_simple_select(node)
      first = node.children[0]
      return visit_children(node) if first.is_a?(Node) && first.name == :select_clause

      level = (@levels[node] ||= new_level)
      previous = nil
      @stack << lambda do
        finish_select(level, node)
        @level = previous
      end
      if first.is_a?(Token) && first.type == :TABLE
        add_relation(level, node.children[1], nil, nil)
      elsif first.is_a?(Token)
        group = node.children[6]
        mark_bare_names(group.children[3], :group_by_item) unless group.children.empty?
      end
      visit_children(node)
      @stack << lambda do
        previous = @level
        @level = level
      end
    end

    def new_level(outputs = nil)
      Level.new(@level, [], nil, outputs, nil, 0, nil, from_scope)
    end

    NOTHING_VISIBLE = Set.new.freeze

    # Which FROM items of the current level are certainly visible at this point
    # of the walk. nil outside the level's FROM clause, where all of them are.
    # Inside it PostgreSQL hides items written later and, outside LATERAL,
    # items written earlier, so none are, except in a join's ON condition,
    # which always sees both sides of its join: there, the names of the join's
    # members that no inner join alias hides.
    def from_scope
      level = @level
      return nil unless level && level.from_depth > 0

      case (scope = level.on_clause)
      when nil then NOTHING_VISIBLE
      when Set then scope
      else
        # Taken now, while the walk is in the ON condition: a join alias
        # written around this join hides its members only outside it.
        members = level.entries[scope..]
        spend(members.length)
        level.on_clause = members.filter_map { |member| member.name if !member.hidden && member.name.is_a?(String) }.to_set
      end
    end

    def current_level
      @level || raise(ParseError, "unsupported syntax: name outside a statement")
    end

    # The statement that decides the result columns of a query: the SELECT,
    # VALUES, TABLE, INSERT, UPDATE, DELETE or MERGE left after removing
    # parentheses, WITH, ORDER BY and LIMIT. A set operation takes its columns
    # from its left side; without through_set_operations it has no core.
    def core_of(node, through_set_operations)
      loop do
        case node.name
        when :PreparableStmt, :SelectStmt, :select_clause then node = node.children[0]
        when :select_with_parens then node = node.children[1]
        when :select_no_parens
          node = node.children.find { |c| c.is_a?(Node) && (c.name == :select_clause || c.name == :simple_select) }
        when :simple_select
          first = node.children[0]
          return node unless first.is_a?(Node) && first.name == :select_clause
          return nil unless through_set_operations

          node = first
        else
          return node
        end
      end
    end

    # ORDER BY and GROUP BY accept the name of a result column in place of an
    # expression, but only when the whole item is that one name.
    def mark_output_names(select_no_parens)
      select_no_parens.children.each do |child|
        next unless child.is_a?(Node)

        child = child.children[0] if child.name == :opt_sort_clause
        mark_bare_names(child.children[2], :sortby) if child.is_a?(Node) && child.name == :sort_clause
      end
    end

    def mark_bare_names(list, item_name)
      flatten(list).each do |item|
        next unless item.is_a?(Node) && item.name == item_name

        node = item.children[0]
        while node.is_a?(Node)
          kids = node.children
          if node.name == :columnref
            @alias_refs[node] = true if kids.length == 1
            break
          elsif kids.length == 1
            node = kids[0]
          elsif node.name == :c_expr && kids.length == 4 && kids[0].is_a?(Token) && kids[0].type == "(" &&
              kids[3].children.empty?
            node = kids[1]
          else
            break
          end
        end
      end
    end

    def finish_select(level, node)
      first = node.children[0]
      outputs =
        if first.is_a?(Node)
          row = first
          row = row.children[0] while row.children[0].is_a?(Node)
          count = flatten(row.children[2]).count { |c| c.is_a?(Node) }
          (1..count).map { |n| "column#{n}" }
        elsif first.type == :TABLE
          entry = level.entries[0]
          charge_whole(entry)
          star_columns([entry])
        else
          target = node.children[2]
          target = target.children[0] if target.name == :opt_target_list
          target ? output_names(level, target) : []
        end
      level.outputs = outputs unless level.outputs == :any
      @outputs[node] = outputs
    end

    # The target of INSERT, UPDATE, DELETE or MERGE is visible by name in the
    # statement, and RETURNING can also reach it as OLD and NEW.
    def setup_dml(level, node)
      target = node.children.find { |c| c.is_a?(Node) && (c.name == :relation_expr_opt_alias || c.name == :insert_target) }
      table = relation_name(target)
      alias_name = target.children.reverse.find { |c| c.is_a?(Node) && c.name == :ColId }
      columns = @schema.all_columns(table) || :any
      entry = Entry.new(alias_name ? leaf(alias_name) : table.split(".").last, table, columns)
      level.entries << entry
      level.target = entry

      returning = node.children.last
      return if returning.children.empty?

      names = %w[old new]
      options = returning.children[1].children[2]
      flatten(options).each { |o| names << leaf(o.children[2]) if o.is_a?(Node) } if options
      names.each { |name| level.entries << Entry.new(name, table, columns, nil, nil, true) }
    end

    def finish_dml(level, node)
      returning = node.children.last
      @outputs[node] = returning.children.empty? ? [] : output_names(level, returning.children[2])
    end

    # The names of the columns a target list produces, in order, with nil for
    # a column whose name is not certain; nil when even the number of columns
    # is unknown; :any when a table missing from the schema is involved.
    def output_names(level, target_list)
      names = []
      any = opaque = false
      flatten(target_list).each do |element|
        next unless element.is_a?(Node)

        kids = element.children
        if kids.length > 1
          names << leaf(kids.last)
          next
        end

        if kids[0].is_a?(Token)
          spend(level.entries.length)
          level.entries.each { |entry| charge_whole(entry) unless entry.pseudo }
          columns = star_columns(level.entries)
        else
          figured = figure_name(kids[0])
          unless figured.is_a?(Array)
            names << figured
            next
          end
          # qualifier.*; charged where the reference itself is resolved.
          spend(level.entries.length)
          matches = level.entries.select { |entry| entry.name == figured[0] || entry.name.nil? }
          columns = (matches.length == 1 && !matches[0].hidden) ? star_columns(matches) : nil
        end

        if columns == :any
          any = true
        elsif columns
          names.concat(columns)
        else
          opaque = true
        end
      end
      if any
        :any
      else
        opaque ? nil : names
      end
    end

    # The columns "*" expands to. Entries inside an aliased join are skipped,
    # because the join's alias stands for them, unless the caller is that join.
    def star_columns(entries, joined = false)
      result = []
      any = opaque = false
      entries.each do |entry|
        next if entry.pseudo || (entry.hidden && !joined)

        columns = entry.table ? (@schema.columns(entry.table) || :any) : columns_of(entry)
        if columns == :any
          any = true
        elsif columns
          spend(columns.size)
          result.concat(columns.to_a)
        else
          opaque = true
        end
      end
      if any
        :any
      else
        opaque ? nil : result
      end
    end

    # The name PostgreSQL gives an unlabelled result column, when that is
    # certain: the last name of a column reference, or the name of a function.
    # ["q"] for "q.*". nil for anything else, which leaves the column out of
    # what is known; that can deny a valid query but never allows a bad one.
    def figure_name(node)
      loop do
        kids = node.children
        case node.name
        when :a_expr, :b_expr
          if kids.length == 1 || (kids.length == 3 && kids[1].is_a?(Token) && kids[1].type == :TYPECAST)
            node = kids[0]
          else
            return nil
          end
        when :c_expr
          first = kids[0]
          if kids.length == 1 && first.is_a?(Node)
            node = first
          elsif kids.length == 4 && first.is_a?(Token) && first.type == "("
            name = nil
            flatten(kids[3]).each do |element|
              second = element.children[1]
              return nil if second.is_a?(Token) && second.type == "*"

              name = leaf(second) if second.is_a?(Node) && second.name == :attr_name
            end
            return name if name

            node = kids[1]
          else
            return nil
          end
        when :columnref
          name = leaf(kids[0])
          return name if kids.length == 1

          qualifier = name
          subscripted = false
          flatten(kids[1]).each do |element|
            second = element.children[1]
            if second.is_a?(Node) && second.name == :attr_name
              qualifier = name = leaf(second)
            elsif element.children[0].type == "["
              subscripted = true
            else
              return subscripted ? nil : [qualifier]
            end
          end
          return name
        when :func_expr
          call = kids[0]
          return nil unless call.name == :func_application

          return dotted_name(call.children[0]).split(".").last
        else
          return nil
        end
      end
    end

    # SELECT ... INTO creates a table.
    def visit_into_clause(node)
      raise DisallowedStatementError, "SELECT INTO statements are not allowed" unless node.children.empty?
    end

    # FOR UPDATE / FOR SHARE take row locks and need UPDATE privilege.
    def visit_for_locking_clause(node)
      @kinds << :update if node.children[0].is_a?(Node)
    end

    def visit_on_conflict(node)
      if node.children.any? { |c| c.is_a?(Token) && c.type == :UPDATE }
        @kinds << :update
        level = current_level
        target = level.target
        level.entries << Entry.new("excluded", target.table, target.columns, nil, nil, true) if target
      end
      visit_children(node)
    end

    # --- Relations ---

    # A relation in a FROM clause or after TABLE: a table, unless it is an
    # unqualified name with a CTE of that name in scope.
    def visit_relation_expr(node)
      name = relation_name(node)
      @tables << name unless !name.include?(".") && cte(name)
    end

    # The target of INSERT, UPDATE, DELETE or MERGE is always a real table;
    # PostgreSQL never resolves it to a CTE.
    def visit_target_relation(node)
      @tables << relation_name(node)
    end

    def relation_name(node)
      node = node.children.find { |c| c.is_a?(Node) } until node.name == :qualified_name
      dotted_name(node)
    end

    # --- FROM items ---

    def visit_table_ref(node)
      kids = node.children
      item = kids.find { |c| c.is_a?(Node) }
      level = current_level
      level.from_depth += 1
      @stack << -> { level.from_depth -= 1 }
      case item.name
      when :relation_expr
        name, list = alias_of(kids[1])
        add_relation(level, item, name, list)
      when :func_table
        add_function(level, item, kids.last)
      when :xmltable, :json_table
        name, list = alias_of(kids.last)
        level.entries << Entry.new(name || item.name.to_s, nil, list || declared_columns(item))
      when :select_with_parens
        name, list = alias_of(kids.last)
        core = core_of(item, true)
        level.entries << Entry.new(name || :none, nil, list, list ? nil : -> { @outputs[core] })
      when :joined_table
        if kids[0].is_a?(Token)
          start = level.entries.length
          name, list = alias_of(kids.last)
          @stack << -> { add_join_alias(level, start, name, list) }
        end
      end
      visit_children(node)
    end

    # [alias name, column alias list] of an alias clause; either can be nil.
    def alias_of(node)
      inner = node.children[0]
      node = inner if node.name != :alias_clause && inner.is_a?(Node) && inner.name == :alias_clause
      name = node.children.find { |c| c.is_a?(Node) && c.name == :ColId }
      list = node.children.find { |c| c.is_a?(Node) && (c.name == :name_list || c.name == :TableFuncElementList) }
      [name && leaf(name), list && list_names(list)]
    end

    def list_names(list)
      flatten(list).filter_map do |item|
        next unless item.is_a?(Node)

        leaf((item.name == :TableFuncElement) ? item.children[0] : item)
      end
    end

    # A column alias list renames columns by position. Which columns are left
    # with their own names depends on their order, so only the aliases are
    # taken as known, and a table renamed this way counts as read in full.
    def add_relation(level, relation, alias_name, list)
      table = relation_name(relation)
      if !table.include?(".") && (info = cte(table))
        source = list ? nil : -> { info.columns || @outputs[info.core] }
        level.entries << Entry.new(alias_name || table, nil, list, source)
      elsif list
        @columns << "#{table}.*"
        level.entries << Entry.new(alias_name || table.split(".").last, nil, @schema.table?(table) ? list : :any)
      else
        columns = @schema.all_columns(table) || :any
        level.entries << Entry.new(alias_name || table.split(".").last, table, columns)
      end
    end

    def add_function(level, func_table, alias_clause)
      alias_name, list = alias_of(alias_clause)
      function = nil
      base = nil
      call = func_table.children[0]
      call = call.children[0] if call.is_a?(Node)
      if call.is_a?(Node) && call.name == :func_application
        function = dotted_name(call.children[0])
        # Nothing is assumed about a function the schema does not describe,
        # PostgreSQL's own included.
        case (shape = @schema.function_columns(function))
        when :scalar then base = [alias_name || function.split(".").last]
        when Array then base = shape
        end
      end
      ordinality = !func_table.children.last.children.empty?
      # Like every column list here, this may be fewer names than there really
      # are: WITH ORDINALITY adds a column whatever the function returns.
      columns =
        if list
          (ordinality && base && list.length == base.length) ? list + ["ordinality"] : list
        elsif ordinality
          (base || []) + ["ordinality"]
        else
          base
        end
      # Without an alias a function call is known by its name. Other forms
      # (CURRENT_DATE, COALESCE(...), ROWS FROM (...)) have no certain name.
      level.entries << Entry.new(alias_name || function&.split(".")&.last, nil, columns)
    end

    # The column names written in XMLTABLE(... COLUMNS ...) or JSON_TABLE(... COLUMNS (...)).
    def declared_columns(node)
      names = []
      pending = [node]
      until pending.empty?
        current = pending.pop
        current.children.each do |child|
          next unless child.is_a?(Node)

          case child.name
          when :xmltable_column_list, :json_table_column_definition_list
            flatten(child).each { |item| pending << item if item.is_a?(Node) }
          when :ColId
            names << leaf(child) if current.name == :xmltable_column_el || current.name == :json_table_column_definition
          end
        end
      end
      names
    end

    # "(a JOIN b ...) AS j": j stands for the joined columns, and a and b can
    # no longer be named from outside the join.
    def add_join_alias(level, start, name, list)
      members = level.entries[start..]
      spend(members.length)
      visible = members.reject(&:hidden)
      tables = members.select(&:table)
      members.each { |member| member.hidden = true }
      entry = Entry.new(name, nil, list, nil, tables)
      if list
        tables.each { |member| charge_whole(member) }
      else
        entry.source = -> { star_columns(visible, true) }
      end
      level.entries << entry
    end

    # NATURAL and USING read columns without naming their tables. ON sees the
    # members of its join.
    def visit_joined_table(node)
      kids = node.children
      natural = kids.any? { |c| c.is_a?(Token) && c.type == :NATURAL }
      qual = kids.last
      using = qual.is_a?(Node) && qual.name == :join_qual && qual.children[0].type == :USING
      on = qual.is_a?(Node) && qual.name == :join_qual && qual.children[0].type == :ON
      if natural || using
        level = current_level
        start = level.entries.length
        @stack << lambda do
          tables = level.entries[start..].select(&:table)
          spend(tables.length)
          if natural
            tables.each { |member| charge_whole(member) }
          else
            names = list_names(qual.children[2])
            spend(tables.length * names.length)
            names.each { |column| charge_members(tables, column) }
            alias_node = qual.children[4]
            unless alias_node.children.empty?
              level.entries << Entry.new(leaf(alias_node.children[1]), nil, names, nil, tables)
            end
          end
        end
      end
      if on
        level = current_level
        start = level.entries.length
        @stack << -> { level.on_clause = nil }
        @stack << qual
        @stack << -> { level.on_clause = start }
        visit(kids[0...-1])
      else
        visit_children(node)
      end
    end

    # --- Columns of the target table ---

    # A column assigned by SET or named in an INSERT column list.
    def visit_target_column(node)
      charge_target(leaf(node.children[0]))
      visit(node.children[1..])
    end

    # ON CONFLICT (column, ...)
    def visit_index_elem(node)
      first = node.children[0]
      charge_target(leaf(first)) if first.is_a?(Node) && first.name == :ColId
      visit_children(node)
    end

    # INSERT without a column list writes every column.
    def visit_insert_columns(node)
      charge_target("*") unless node.children.any? { |c| c.is_a?(Node) && c.name == :insert_column_list }
      visit_children(node)
    end

    def charge_target(column)
      target = current_level.target
      raise ParseError, "unsupported syntax: column assignment outside a data-modifying statement" unless target

      @columns << "#{target.table}.#{column}"
    end

    # --- Functions ---

    def visit_func_application(node)
      @functions << dotted_name(node.children[0])
      visit(node.children[1..])
    end

    # Functions with their own syntax: COALESCE(...), EXTRACT(... FROM ...),
    # CURRENT_USER, JSON_OBJECT(...), XMLTABLE(...), and so on. The function is
    # named after its keyword. CAST and TREAT are type conversions, recorded
    # through their type name.
    def visit_keyword_function(node)
      keyword = node.children[0]
      case keyword.type
      when :CAST, :TREAT then nil
      when :COLLATION then @functions << "pg_collation_for"
      else @functions << keyword.value
      end
      visit_children(node)
    end

    def visit_c_expr(node)
      first = node.children[0]
      @functions << "grouping" if first.is_a?(Token) && first.type == :GROUPING
      node.children.each do |child|
        next unless child.is_a?(Node) && (child.name == :indirection || child.name == :opt_indirection)

        # (expr).name, $1.name, (SELECT ...).name
        flatten(child).each do |element|
          attribute = element.children[1]
          record_attribute_call(leaf(attribute)) if attribute.is_a?(Node) && attribute.name == :attr_name
        end
      end
      visit_children(node)
    end

    # --- Column references and attribute notation ---
    #
    # PostgreSQL treats "x.name" as the function call "name(x)" whenever x has
    # no column called name. That is how computed columns work, but it applies
    # to every function and every x, so it is a second way to write a function
    # call. Every reference is therefore resolved against the schema:
    #
    # * "(expr).name" and anything after a subscript always counts as a
    #   possible call of name.
    # * "alias.name" is a column only if name is certainly a column of
    #   everything alias could refer to: what candidates finds, from this
    #   query level out to the nearest one PostgreSQL would certainly bind it
    #   to. Otherwise it counts as a call of name on the whole row.
    # * A bare name is never a call, but it must be found: as a column of
    #   something in FROM at this level or an enclosing one, or as the name of
    #   a FROM item (a whole-row reference). A name that cannot be found is
    #   refused, so that a column missing from the schema is never read.
    #
    # Resolution waits until the whole query has been walked, because a name
    # can refer to a FROM item that is written after it.

    def record_attribute_call(name)
      @functions << checked(name)
    end

    def visit_columnref(node)
      names = [leaf(node.children[0])]
      star = subscripted = false
      if (indirection = node.children[1])
        flatten(indirection).each do |element|
          attribute = element.children[1]
          if attribute.is_a?(Node) && attribute.name == :attr_name
            if subscripted
              record_attribute_call(leaf(attribute))
            else
              names << leaf(attribute)
            end
          elsif element.children[0].type == "["
            subscripted = true
            visit_children(element)
          elsif !subscripted
            star = true
          end
        end
      end
      @refs << [current_level, names, star, @alias_refs.key?(node), from_scope]
    end

    def resolve_ref(level, names, star, alias_ok, in_from)
      return resolve_bare_name(level, names[0], alias_ok) if names.length == 1 && !star

      # [catalog.][schema.]qualifier.column, or [catalog.][schema.]qualifier.*
      qualifier = star ? names[-1] : names[-2]
      # A schema-qualified qualifier matches only some of the FROM items of
      # its name, so it is never taken to stop at the nearest.
      nearest = names.length == (star ? 1 : 2)
      found = candidates(level, qualifier, nearest, in_from)
      if found.empty?
        raise UnresolvedNameError, "#{names.join(".").inspect} refers to #{qualifier.inspect}, which is not in FROM"
      end

      column = names[-1]
      found.each do |entry|
        if star
          charge_whole(entry)
          next
        end
        columns = columns_of(entry)
        next if columns == :any

        if columns&.include?(column)
          charge(entry, column)
        else
          record_attribute_call(column)
          charge_whole(entry)
        end
      end
    end

    def resolve_bare_name(level, name, alias_ok)
      outputs = level.outputs
      found = alias_ok && (outputs == :any || (outputs && outputs.include?(name)))
      column_found = false
      rows = nil
      while level
        spend(1)
        index = index_of(level)
        found = true if index.any
        if (tables = index.columns[name])
          found = column_found = true
          tables.each { |table| @columns << "#{table}.#{name}" }
        end
        if (entries = index.names[name])
          (rows ||= []).concat(entries)
        end
        level = level.parent
      end
      # A name that is not a column anywhere is a whole-row reference to the
      # FROM item of that name.
      rows&.each do |entry|
        next if entry.pseudo && column_found

        found = true
        charge_whole(entry)
      end
      raise UnresolvedNameError, "column #{name.inspect} cannot be resolved" unless found
    end

    # Everything the qualifier could refer to, from this level outward.
    # PostgreSQL binds a qualifier to the nearest level with a FROM item of
    # that name and never looks further out, so the walk stops at a level with
    # an entry that is certainly named qualifier and certainly visible from
    # the reference. Entries of uncertain name at that level or nearer stay
    # candidates. Inside a level's FROM clause, where PostgreSQL hides later
    # and non-LATERAL items, in_from names the items the reference certainly
    # sees (the members of the join whose ON condition it is in), and the walk
    # goes on past the level unless qualifier is one of them. It also goes on
    # past entries that are hidden by a join alias or are OLD, NEW or
    # EXCLUDED, which are not visible everywhere in their level.
    def candidates(level, qualifier, nearest, in_from)
      found = []
      while level
        index = index_of(level)
        entries = index.names[qualifier]
        found.concat(entries) if entries
        found.concat(index.wildcards)
        spend(1 + found.length)
        if nearest && entries
          return found if in_from ? in_from.include?(qualifier) : entries.any? { |entry| !entry.hidden && !entry.pseudo }
        end

        in_from = level.in_parent_from
        level = level.parent
      end
      found
    end

    def index_of(level)
      index = level.index
      return index if index

      index = level.index = LevelIndex.new(false, {}, {}, [])
      seen = {}
      spend(level.entries.length)
      level.entries.each do |entry|
        name = entry.name
        if name.nil?
          index.wildcards << entry
        elsif name != :none
          (index.names[name] ||= []) << entry
        end

        columns = columns_of(entry)
        if columns == :any
          index.any = true
          next
        end
        next unless columns

        table = entry.table
        next if table && seen[table]

        seen[table] = true if table
        spend(columns.size)
        columns.each do |column|
          tables = (index.columns[column] ||= []) if column
          tables << table if table && column
        end
      end
      index
    end

    def columns_of(entry)
      columns = entry.columns
      return columns if columns || !entry.source

      columns = entry.source.call
      entry.columns = columns if @final
      columns
    end

    def charge(entry, column)
      if entry.table
        @columns << "#{entry.table}.#{column}"
      elsif entry.members
        spend(entry.members.length)
        charge_members(entry.members, column)
      end
    end

    def charge_members(tables, column)
      tables.each { |member| @columns << "#{member.table}.#{column}" if @schema.column?(member.table, column) }
    end

    def charge_whole(entry)
      if entry.table
        @columns << "#{entry.table}.*"
      elsif entry.members
        spend(entry.members.length)
        entry.members.each { |member| @columns << "#{member.table}.*" }
      end
    end

    def spend(amount)
      @work -= amount
      raise ParseError, "query is too complex to analyze" if @work < 0
    end

    # TABLESAMPLE method(...): the sampling method is a function.
    def visit_tablesample_clause(node)
      @functions << dotted_name(node.children[1])
      visit(node.children[2..])
    end

    # --- Types ---
    #
    # Every Typename, SimpleTypename and ConstTypename reduces to one of these.
    # Array bounds, SETOF and type modifiers are not part of the recorded name.

    def visit_generic_type(node)
      parts = [leaf(node.children[0])]
      rest = node.children[1..]
      if rest[0].is_a?(Node) && rest[0].name == :attrs
        flatten(rest[0]).each { |c| parts << leaf(c) if c.is_a?(Node) }
      end
      @types << parts.map { |part| checked(part) }.join(".")
      visit(rest.reject { |c| c.is_a?(Node) && c.name == :attrs })
    end

    def visit_numeric_type(node)
      @types << NUMERIC_TYPES.fetch(node.children[0].type)
      visit_children(node)
    end

    def visit_bit_type(node)
      varying = !node.children[1].children.empty?
      @types << (varying ? "bit varying" : "bit")
      visit_children(node)
    end

    def visit_character_type(node)
      varying = node.children.any? do |c|
        c.is_a?(Token) ? c.type == :VARCHAR : !c.children.empty?
      end
      @types << (varying ? "character varying" : "character")
    end

    def visit_datetime_type(node)
      base = (node.children[0].type == :TIMESTAMP) ? "timestamp" : "time"
      zone = node.children.last.children[0]
      @types << ((zone && zone.type == :WITH_LA) ? "#{base} with time zone" : base)
    end

    def visit_interval_type(_node)
      @types << "interval"
    end

    def visit_json_type(_node)
      @types << "json"
    end

    # A constant. "name 'literal'" and "name(modifiers) 'literal'" are casts of
    # the literal to the type called name, even though name is written with the
    # grammar's func_name.
    def visit_constant(node)
      first = node.children[0]
      if first.is_a?(Node) && first.name == :func_name
        @types << dotted_name(first)
        visit(node.children[1..])
      else
        visit_children(node)
      end
    end

    # --- Names ---

    # The text of a single-identifier nonterminal (ColId, type_function_name,
    # ColLabel, name, attr_name, ...).
    def leaf(node)
      node = node.children[0] while node.is_a?(Node)
      node.value
    end

    # A possibly qualified name: qualified_name, func_name (ColId indirection,
    # or a single identifier). Subscripts and ".*" are not valid in a name.
    def dotted_name(node)
      parts = [leaf(node.children[0])]
      if (indirection = node.children[1])
        flatten(indirection).each do |element|
          attribute = element.children[1]
          unless element.children.length == 2 && attribute.is_a?(Node) && attribute.name == :attr_name
            raise ParseError, "unsupported syntax: subscript or * in a name"
          end
          parts << leaf(attribute)
        end
      end
      parts.map { |part| checked(part) }.join(".")
    end

    # Names are recorded with their parts joined by dots, so a part that itself
    # contains a dot would be indistinguishable from a qualified name.
    def checked(part)
      if part.include?(".")
        raise ParseError, "quoted identifier containing a dot is not supported: \"#{part}\""
      end
      part
    end

    # The items of a left-recursive list production (x: item | x sep item), in
    # source order, without recursing.
    def flatten(node)
      groups = []
      loop do
        children = node.children
        first = children[0]
        if first.is_a?(Node) && first.name == node.name
          groups << children[1..]
          node = first
        else
          groups << children
          break
        end
      end
      groups.reverse.flatten(1)
    end
  end
end
