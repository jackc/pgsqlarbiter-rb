# frozen_string_literal: true

require "set"

module Pgsqlarbiter
  # A whitelist of PostgreSQL functions safe for use in queries. This includes functions that could
  # cause resource exhaustion (e.g. generate_series) — resource limits should be enforced elsewhere.
  #
  # Excluded: functions not used by regular queries such as pg_sleep, set_config, lo_*, pg_advisory_lock,
  # pg_notify, sequence functions, and system information functions.
  SAFE_FUNCTIONS = Set[
    # -- Aggregate functions --
    "array_agg", "avg", "bit_and", "bit_or", "bit_xor",
    "bool_and", "bool_or", "count", "every",
    "json_agg", "jsonb_agg", "json_object_agg", "jsonb_object_agg",
    "max", "min", "range_agg", "range_intersect_agg",
    "string_agg", "sum", "xmlagg",

    # -- Statistical aggregate functions --
    "corr", "covar_pop", "covar_samp",
    "regr_avgx", "regr_avgy", "regr_count", "regr_intercept",
    "regr_r2", "regr_slope", "regr_sxx", "regr_sxy", "regr_syy",
    "stddev", "stddev_pop", "stddev_samp",
    "variance", "var_pop", "var_samp",

    # -- Ordered-set aggregate functions --
    "mode", "percentile_cont", "percentile_disc",

    # -- Window functions --
    "row_number", "rank", "dense_rank", "percent_rank", "cume_dist",
    "ntile", "lag", "lead", "first_value", "last_value", "nth_value",

    # -- Mathematical functions --
    "abs", "cbrt", "ceil", "ceiling", "degrees", "div",
    "exp", "factorial", "floor", "gcd", "lcm",
    "ln", "log", "log10", "min_scale", "mod",
    "pi", "power", "radians", "random",
    "round", "scale", "sign", "sqrt",
    "trim_scale", "trunc", "width_bucket",

    # -- Trigonometric functions --
    "acos", "acosd", "asin", "asind",
    "atan", "atan2", "atan2d", "atand",
    "cos", "cosd", "cot", "cotd",
    "sin", "sind", "tan", "tand",

    # -- Hyperbolic functions --
    "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",

    # -- String functions --
    "ascii", "btrim", "char_length", "character_length",
    "chr", "concat", "concat_ws",
    "convert", "convert_from", "convert_to",
    "decode", "encode", "format",
    "initcap", "left", "length", "lower",
    "lpad", "ltrim", "md5",
    "normalize", "octet_length", "overlay",
    "parse_ident", "position",
    "quote_ident", "quote_literal", "quote_nullable",
    "regexp_count", "regexp_instr", "regexp_like",
    "regexp_match", "regexp_matches", "regexp_replace",
    "regexp_split_to_array", "regexp_split_to_table", "regexp_substr",
    "repeat", "replace", "reverse", "right",
    "rpad", "rtrim", "split_part",
    "starts_with", "string_to_array", "string_to_table",
    "strpos", "substr", "substring",
    "to_ascii", "to_hex", "translate", "trim",
    "unicode", "unistr", "upper",

    # -- Binary string functions --
    "bit_length", "get_bit", "get_byte",
    "set_bit", "set_byte",
    "sha224", "sha256", "sha384", "sha512",

    # -- Date/time functions --
    "age", "clock_timestamp", "date_bin",
    "date_part", "date_trunc", "extract",
    "isfinite", "justify_days", "justify_hours", "justify_interval",
    "make_date", "make_interval", "make_time",
    "make_timestamp", "make_timestamptz",
    "now", "statement_timestamp",
    "timeofday", "transaction_timestamp",

    # -- Formatting functions --
    "to_char", "to_date", "to_number", "to_timestamp",

    # -- Conditional functions --
    "coalesce", "nullif", "greatest", "least",

    # -- Comparison functions --
    "num_nulls", "num_nonnulls",

    # -- JSON/JSONB functions --
    "to_json", "to_jsonb", "array_to_json", "row_to_json",
    "json_build_array", "jsonb_build_array",
    "json_build_object", "jsonb_build_object",
    "json_object", "jsonb_object",
    "json_array", "jsonb_array",
    "json_array_length", "jsonb_array_length",
    "json_each", "jsonb_each",
    "json_each_text", "jsonb_each_text",
    "json_extract_path", "jsonb_extract_path",
    "json_extract_path_text", "jsonb_extract_path_text",
    "json_object_keys", "jsonb_object_keys",
    "json_populate_record", "jsonb_populate_record",
    "json_populate_recordset", "jsonb_populate_recordset",
    "json_to_record", "jsonb_to_record",
    "json_to_recordset", "jsonb_to_recordset",
    "json_strip_nulls", "jsonb_strip_nulls",
    "jsonb_set", "jsonb_set_lax", "jsonb_insert",
    "jsonb_path_exists", "jsonb_path_match",
    "jsonb_path_query", "jsonb_path_query_array", "jsonb_path_query_first",
    "jsonb_path_exists_tz", "jsonb_path_match_tz",
    "jsonb_path_query_tz", "jsonb_path_query_array_tz", "jsonb_path_query_first_tz",
    "jsonb_pretty",
    "json_typeof", "jsonb_typeof",
    "json_array_elements", "jsonb_array_elements",
    "json_array_elements_text", "jsonb_array_elements_text",
    "json_scalar", "jsonb_scalar",
    "json_table",

    # -- Array functions --
    "array_append", "array_cat", "array_dims", "array_fill",
    "array_length", "array_lower", "array_ndims",
    "array_position", "array_positions",
    "array_prepend", "array_remove", "array_replace",
    "array_sample", "array_shuffle",
    "array_to_string", "array_upper",
    "cardinality", "trim_array", "unnest",

    # -- Range/multirange functions --
    "isempty", "lower_inc", "upper_inc", "lower_inf", "upper_inf",
    "range_merge", "multirange",
    "int4range", "int8range", "numrange",
    "tsrange", "tstzrange", "daterange",
    "int4multirange", "int8multirange", "nummultirange",
    "tsmultirange", "tstzmultirange", "datemultirange",

    # -- Set-returning functions --
    "generate_series", "generate_subscripts",

    # -- Geometric functions --
    "area", "center", "diagonal", "diameter", "height",
    "isclosed", "isopen", "npoints",
    "pclose", "popen", "radius", "slope", "width",
    "box", "circle", "line", "lseg", "path", "point", "polygon",

    # -- Network address functions --
    "abbrev", "broadcast", "family",
    "host", "hostmask", "inet_merge", "inet_same_family",
    "masklen", "netmask", "network", "set_masklen",

    # -- Text search functions --
    "array_to_tsvector", "numnode",
    "plainto_tsquery", "phraseto_tsquery",
    "querytree", "setweight", "strip",
    "to_tsquery", "to_tsvector",
    "ts_delete", "ts_filter", "ts_headline", "ts_lexize",
    "ts_rank", "ts_rank_cd", "ts_rewrite",
    "tsvector_to_array", "websearch_to_tsquery",

    # -- XML functions --
    "xmlcomment", "xmlconcat", "xmlexists",
    "xmlelement", "xmlforest", "xmlparse", "xmlroot", "xmlserialize",
    "xmltable",
    "xpath", "xpath_exists",

    # -- Grouping function --
    "grouping",

    # -- Enum functions --
    "enum_first", "enum_last", "enum_range",

    # -- UUID functions --
    "gen_random_uuid", "uuidv4", "uuidv7"
  ].freeze
end
