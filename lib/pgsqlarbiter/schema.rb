# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  # What exists in the database: the columns of every table and view, and
  # optionally the result columns of functions that are used in +FROM+.
  #
  # The analyzer needs this to tell a column from a function. PostgreSQL treats
  # +x.name+ as the call +name(x)+ when +x+ has no column +name+, so without the
  # column lists a function call can hide in what looks like a column reference.
  #
  # A schema describes the database; it grants nothing. What a query may use is
  # decided by the {Arbiter}'s whitelists.
  #
  # Every column of a table must be listed, including columns that no query will
  # be allowed to use. Names are matched exactly as queries write them, after
  # PostgreSQL's case folding: +users+ and +public.users+ are separate entries.
  #
  # Keep the schema current. A column that is missing from it is denied, which
  # is safe. A column that is listed but no longer exists is treated as a
  # column while PostgreSQL would look for a function of that name.
  #
  # @example
  #   schema = Pgsqlarbiter::Schema.new(
  #     {"users" => %w[id name email password_hash], "orders" => %w[id user_id total]},
  #     functions: {"monthly_report" => %w[month total], "active_user_ids" => :scalar}
  #   )
  class Schema
    # Columns that every table has.
    SYSTEM_COLUMNS = %w[tableoid xmin cmin xmax cmax ctid].freeze

    # A query that describes the connected database as one JSON document for
    # {Schema.load}. Run it as the role, and with the +search_path+, that the
    # restricted queries will use.
    #
    # Tables, views, materialized views and foreign tables outside the system
    # schemas are listed as +schema.name+, and also as the bare +name+ when the
    # +search_path+ finds them that way.
    #
    # Functions are listed with the columns they return in +FROM+, PostgreSQL's
    # own functions included, as +schema.name+ and as the bare +name+. A name
    # is listed only when every function it can reach returns the same columns.
    # PostgreSQL chooses among the functions of one name by the arguments of
    # each call, so nothing can be said about a name whose functions differ, or
    # about one that returns whatever type it is given (+unnest+).
    #
    # Names containing a dot, and columns named +*+, are left out because
    # pgsqlarbiter cannot represent them; queries that use them are denied.
    QUERY = <<~SQL
      WITH rels AS (
        SELECT c.oid, n.nspname, c.relname, pg_catalog.pg_table_is_visible(c.oid) AS visible,
               (SELECT coalesce(pg_catalog.jsonb_agg(a.attname ORDER BY a.attnum), '[]'::jsonb)
                  FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                   AND a.attname <> '*' AND pg_catalog.strpos(a.attname, '.') = 0) AS columns
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'v', 'm', 'f', 'p')
           AND n.nspname <> 'pg_catalog' AND n.nspname <> 'information_schema'
           AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp'
           AND pg_catalog.strpos(n.nspname, '.') = 0 AND pg_catalog.strpos(c.relname, '.') = 0
      ),
      funcs AS (
        SELECT n.nspname, p.proname, pg_catalog.pg_function_is_visible(p.oid) AS visible,
               CASE
                 -- Several OUT or TABLE parameters: a row of those columns.
                 WHEN o.outputs > 1 THEN o.names
                 -- A composite type: its attributes.
                 WHEN t.typtype = 'c'
                   THEN (SELECT CASE WHEN bool_and(a.attname <> '*' AND pg_catalog.strpos(a.attname, '.') = 0)
                                     THEN pg_catalog.jsonb_agg(a.attname ORDER BY a.attnum) END
                           FROM pg_catalog.pg_attribute a
                          WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped)
                 -- A single value: named after its one OUT parameter if that has
                 -- a name, otherwise after the alias. A polymorphic or record
                 -- result is neither known to be a value nor a row.
                 WHEN t.typtype IN ('b', 'e', 'r', 'm')
                   THEN CASE WHEN o.outputs = 1 AND o.names IS NOT NULL THEN o.names
                             WHEN o.outputs = 1 AND o.unnamed = 0 THEN NULL
                             ELSE '"scalar"'::jsonb END
               END AS shape
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_catalog.pg_type t ON t.oid = p.prorettype
          CROSS JOIN LATERAL (
            SELECT count(*) AS outputs,
                   count(*) FILTER (WHERE coalesce(x.name, '') = '') AS unnamed,
                   CASE WHEN count(*) > 0
                         AND bool_and(coalesce(x.name, '') <> '' AND x.name <> '*' AND pg_catalog.strpos(x.name, '.') = 0)
                        THEN pg_catalog.jsonb_agg(x.name ORDER BY x.ord) END AS names
              FROM ROWS FROM (pg_catalog.unnest(p.proargmodes), pg_catalog.unnest(p.proargnames))
                   WITH ORDINALITY AS x(mode, name, ord)
             WHERE x.mode IN ('o', 'b', 't')
          ) o
         WHERE p.prokind = 'f' AND pg_catalog.strpos(p.proname, '.') = 0
           AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp'
      ),
      named_funcs AS (
        SELECT nspname || '.' || proname AS name, shape FROM funcs WHERE pg_catalog.strpos(nspname, '.') = 0
        UNION ALL
        SELECT proname, shape FROM funcs WHERE visible
      ),
      agreed_funcs AS (
        SELECT name, min(shape::text)::jsonb AS shape
          FROM named_funcs
         GROUP BY name
        HAVING count(*) = count(shape) AND count(DISTINCT shape::text) = 1
      )
      SELECT pg_catalog.jsonb_build_object(
        'tables', coalesce((SELECT pg_catalog.jsonb_object_agg(name, columns) FROM (
                    SELECT nspname || '.' || relname AS name, columns FROM rels
                    UNION ALL
                    SELECT relname, columns FROM rels WHERE visible) t), '{}'::jsonb),
        'functions', coalesce((SELECT pg_catalog.jsonb_object_agg(name, shape) FROM agreed_funcs), '{}'::jsonb)
      )::text
    SQL

    # Build a schema from the JSON document produced by {QUERY}.
    #
    # @param json [String, Hash] the document, or the Hash parsed from it
    # @return [Schema]
    def self.load(json)
      if json.is_a?(String)
        require "json"
        json = JSON.parse(json)
      end
      raise ArgumentError, "schema document must be an object" unless json.is_a?(Hash)

      functions = (json["functions"] || {}).transform_values do |shape|
        if shape.nil?
          :unknown
        else
          (shape == "scalar") ? :scalar : shape
        end
      end
      new(json["tables"] || {}, functions: functions)
    end

    # @param tables [Hash{String => Array<String>}] every column of every table
    #   and view, by table name
    # @param functions [Hash{String => Array<String>, Symbol}] for functions
    #   used in +FROM+, PostgreSQL's own included: the names of the columns the
    #   function returns, +:scalar+ when it returns a single value that takes
    #   the name of its alias, or +:unknown+. Nothing is assumed about a
    #   function that is not listed: it can still be used in +FROM+, but its
    #   columns can only be referred to through a column alias list
    #   (+FROM f() AS t(a, b)+). A name stands for every function a call of it
    #   can reach, so declare columns only when all of them return the same;
    #   {QUERY} works that out from the catalog
    # @raise [ArgumentError] if a name cannot be represented
    def initialize(tables, functions: {})
      raise ArgumentError, "tables must be a Hash of table name to column names" unless tables.is_a?(Hash)
      raise ArgumentError, "functions must be a Hash" unless functions.is_a?(Hash)

      @columns = {}
      @column_sets = {}
      tables.each do |table, columns|
        table = name!(table, "table")
        raise ArgumentError, "columns of #{table.inspect} must be an Array" unless columns.respond_to?(:to_ary)

        columns = columns.to_ary.map { |column| column_name!(column, table) }.freeze
        @columns[table] = columns
        @column_sets[table] = Set.new(columns).merge(SYSTEM_COLUMNS).freeze
      end
      @functions = {}
      functions.each do |function, shape|
        function = name!(function, "function")
        @functions[function] =
          if shape == :scalar || shape == :unknown
            shape
          elsif shape.respond_to?(:to_ary)
            shape.to_ary.map { |column| column_name!(column, function) }.freeze
          else
            raise ArgumentError, "result of function #{function.inspect} must be :scalar, :unknown or an Array of column names"
          end
      end
      @columns.freeze
      @column_sets.freeze
      @functions.freeze
      freeze
    end

    # @return [Array<String>] the names of all tables
    def tables
      @columns.keys
    end

    # @return [Boolean] whether the table is described by this schema
    def table?(table)
      @columns.key?(table)
    end

    # @return [Array<String>, nil] the table's columns as given, or +nil+ for
    #   an unknown table
    def columns(table)
      @columns[table]
    end

    # @return [Set<String>, nil] the table's columns together with the system
    #   columns every table has, or +nil+ for an unknown table
    def all_columns(table)
      @column_sets[table]
    end

    # @return [Boolean] whether the table has the column
    def column?(table, column)
      @column_sets[table]&.include?(column) || false
    end

    # @return [Array<String>, Symbol, nil] the declared result of a function:
    #   column names, +:scalar+, +:unknown+, or +nil+ when it is not listed
    def function_columns(function)
      @functions[function]
    end

    private

    def name!(name, kind)
      name = name.to_s if name.is_a?(Symbol)
      raise ArgumentError, "#{kind} name must be a non-empty String, got #{name.inspect}" unless name.is_a?(String) && !name.empty?

      name.dup.freeze
    end

    def column_name!(column, owner)
      column = name!(column, "column")
      if column == "*" || column.include?(".")
        raise ArgumentError, "column #{column.inspect} of #{owner.inspect} cannot be represented; leave it out " \
                             "of the schema and queries that use it will be denied"
      end
      column
    end
  end
end
