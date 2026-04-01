# frozen_string_literal: true

require_relative "lib/pgsqlarbiter/version"

Gem::Specification.new do |spec|
  spec.name = "pgsqlarbiter"
  spec.version = Pgsqlarbiter::VERSION
  spec.authors = ["pgsqlarbiter contributors"]
  spec.summary = "SQL query permission system for PostgreSQL"
  spec.description = "Restricts SQL queries to single-statement DML with whitelisted tables, views, and functions."
  spec.required_ruby_version = ">= 3.2"
  spec.license = "MIT"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
