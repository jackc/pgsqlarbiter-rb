# frozen_string_literal: true

require "minitest/autorun"
require "pgsqlarbiter"

# With no tables in the schema every table is unknown, and the analyzer then
# accepts any column of it. That suits tests of what the analyzer extracts;
# tests of column resolution build their own schema.
# What Schema::QUERY reports for a few of PostgreSQL's own functions.
BUILTIN_FUNCTIONS = {
  "generate_series" => :scalar, "pg_catalog.generate_series" => :scalar,
  "jsonb_array_elements" => %w[value],
  "json_each" => %w[key value], "jsonb_each" => %w[key value],
  "json_each_text" => %w[key value], "pg_catalog.json_each_text" => %w[key value]
}.freeze

EMPTY_SCHEMA = Pgsqlarbiter::Schema.new({}, functions: BUILTIN_FUNCTIONS)

# The database the whitelist tests pretend to talk to.
TEST_SCHEMA = Pgsqlarbiter::Schema.new({
  "users" => %w[id name email age active created_at data tags],
  "orders" => %w[id user_id total status created_at],
  "order_items" => %w[id order_id product_id quantity price],
  "people" => %w[id name],
  "other" => %w[id name],
  "logs" => %w[id message created_at],
  "events" => %w[id name created_at],
  "t" => %w[id a b c x],
  "my schema.my table" => %w[id]
}, functions: BUILTIN_FUNCTIONS)
