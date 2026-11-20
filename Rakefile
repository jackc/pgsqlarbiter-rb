# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end

namespace :test do
  desc "Check analysis against a live PostgreSQL (connection from PG* variables)"
  task :postgres do
    ruby "test/postgres/oracle.rb"
  end

  desc "Fuzz the lexer against a live PostgreSQL (COUNT and SEED are optional)"
  task :postgres_fuzz do
    ruby "test/postgres/fuzz.rb", *[ENV["COUNT"], ENV["SEED"]].compact
  end

  desc "Fuzz name resolution against a live PostgreSQL (COUNT and SEED are optional)"
  task :postgres_fuzz_names do
    ruby "test/postgres/fuzz_names.rb", *[ENV["COUNT"], ENV["SEED"]].compact
  end

  desc "Check that breaking each name-resolution rule fails a test (needs a live PostgreSQL)"
  task :mutation do
    ruby "test/mutation.rb"
  end
end

# The parser and keyword table are generated from PostgreSQL's sources. To move
# to another PostgreSQL release, change POSTGRESQL_TAG, run
# `rake grammar:fetch grammar:generate`, review the diff of grammar/pg_dml.y,
# and run all the tests, including the live ones.
namespace :grammar do
  POSTGRESQL_TAG = "REL_18_7"
  POSTGRESQL_FILES = %w[
    src/backend/parser/gram.y
    src/include/parser/kwlist.h
    COPYRIGHT
  ].freeze
  source_dir = File.join("tmp", "postgres-#{POSTGRESQL_TAG}")

  desc "Download the PostgreSQL #{POSTGRESQL_TAG} sources the parser is generated from"
  task :fetch do
    require "open-uri"
    mkdir_p source_dir
    POSTGRESQL_FILES.each do |path|
      url = "https://raw.githubusercontent.com/postgres/postgres/#{POSTGRESQL_TAG}/#{path}"
      File.write(File.join(source_dir, File.basename(path)), URI.parse(url).read)
    end
  end

  desc "Regenerate lib/pgsqlarbiter/parser.rb and keywords.rb (needs the racc gem)"
  task :generate do
    ruby "grammar/generate.rb", source_dir, POSTGRESQL_TAG
  end
end

task default: :test
