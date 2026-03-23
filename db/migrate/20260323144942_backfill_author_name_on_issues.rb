class BackfillAuthorNameOnIssues < ActiveRecord::Migration[8.1]
  # Step 2 of 3: Backfill existing NULL rows in batches.
  #
  # Key rules:
  #   1. Use update_all — no Ruby objects loaded, pure SQL, fast
  #   2. Process in batches — never lock the whole table at once
  #   3. Never reference application models (Issue) — they may change
  #      between when this migration was written and when it runs.
  #      Use the raw connection or a migration-local model instead.
  #   4. disable_ddl_transaction! — allows the DB to serve reads/writes
  #      between batches since each batch commits independently.

  disable_ddl_transaction!

  def up
    # Migration-local anonymous model — immune to future app model changes
    issue_relation = define_model("issues", :author_name, :id)

    issue_relation.where(author_name: nil).in_batches(of: 1000) do |batch|
      batch.update_all(author_name: "unknown")
      sleep(0.01) # brief pause — avoids overwhelming the DB on large tables
    end
  end

  def down
    # Reversing a backfill is usually a no-op
  end

  private

  def define_model(table, *columns)
    Class.new(ActiveRecord::Base) { self.table_name = table }
  end
end
