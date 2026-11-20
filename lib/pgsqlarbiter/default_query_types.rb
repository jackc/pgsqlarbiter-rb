# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  # Default set of PostgreSQL types a query may name: in a cast (+x::type+,
  # +CAST(x AS type)+), a typed literal (+type 'text'+), or a column
  # definition list.
  #
  # Types written with SQL-standard keywords are recorded under one canonical
  # name whatever the spelling: +int+ and +integer+ are "integer"; +decimal+,
  # +dec+ and +numeric+ are "numeric"; +char+, +character+ and +nchar+ are
  # "character"; +varchar+ and +character varying+ are "character varying";
  # +timestamp without time zone+ is "timestamp". Every other type is recorded
  # exactly as written, so aliases such as +int4+ and +timestamptz+ are listed
  # separately. Array types are recorded as their element type.
  #
  # Excluded: the object identifier types (regclass, regproc, regtype, ...),
  # which look up catalog objects by name, and oid and name.
  DEFAULT_QUERY_TYPES = Set[
    # -- Numeric --
    "smallint", "integer", "bigint", "int2", "int4", "int8",
    "real", "float", "double precision", "float4", "float8",
    "numeric", "money",

    # -- Boolean --
    "boolean", "bool",

    # -- Character and binary --
    "text", "character", "character varying", "bpchar", "bytea",
    "bit", "bit varying", "varbit",

    # -- Date/time --
    "date", "time", "time with time zone", "timetz",
    "timestamp", "timestamp with time zone", "timestamptz",
    "interval",

    # -- UUID, JSON, XML --
    "uuid", "json", "jsonb", "jsonpath", "xml",

    # -- Network --
    "inet", "cidr", "macaddr", "macaddr8",

    # -- Text search --
    "tsvector", "tsquery",

    # -- Geometric --
    "point", "line", "lseg", "box", "path", "polygon", "circle",

    # -- Range and multirange --
    "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange",
    "int4multirange", "int8multirange", "nummultirange",
    "tsmultirange", "tstzmultirange", "datemultirange"
  ].freeze
end
