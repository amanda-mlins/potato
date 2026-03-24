# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
abort("The Rails environment is running in production mode!") if Rails.env.production?
require 'rspec/rails'
require 'shoulda/matchers'
require 'database_cleaner/active_record'

# Ensures that the test database schema matches the current schema file.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

# Auto-load everything under spec/support/
Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

RSpec.configure do |config|
  # Infer spec type from file location (spec/models -> :model, etc.)
  config.infer_spec_type_from_file_location!

  # Filter Rails gem frames from backtraces
  config.filter_rails_from_backtrace!

  # ---------------------------------------------------------------
  # FactoryBot — mix in shorthand methods (create, build, etc.)
  # GitLab calls `create(:project)` not `FactoryBot.create(:project)`
  # ---------------------------------------------------------------
  config.include FactoryBot::Syntax::Methods

  # ---------------------------------------------------------------
  # DatabaseCleaner — transaction strategy (fast, GitLab default)
  # Each example is wrapped in a transaction that is rolled back,
  # so primary keys/sequences are NOT reset between specs.
  # ---------------------------------------------------------------
  config.use_transactional_fixtures = false

  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning { example.run }
  end
end

# ---------------------------------------------------------------
# Shoulda::Matchers — one-liner validation/association matchers
# ---------------------------------------------------------------
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
