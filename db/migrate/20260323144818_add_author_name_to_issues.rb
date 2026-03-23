class AddAuthorNameToIssues < ActiveRecord::Migration[8.1]
  # Step 1 of 3 (zero-downtime pattern):
  # Add the column as nullable with no default.
  # The app keeps running — old code ignores this column, new code can write to it.
  # No table rewrite, no lock, instant on any table size.
  def change
    add_column :issues, :author_name, :string
    # Deliberately nullable — we backfill data separately (Step 2)
    # We add NOT NULL constraint only after backfill is complete (Step 3)
  end
end
