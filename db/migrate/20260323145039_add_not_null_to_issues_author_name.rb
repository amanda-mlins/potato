class AddNotNullToIssuesAuthorName < ActiveRecord::Migration[8.1]
  # Step 3 of 3: Now that every row has a value, enforce the constraint.
  #
  # PostgreSQL 12+ supports NOT VALID + VALIDATE CONSTRAINT which is
  # the safest approach for large tables:
  #   - ADD CONSTRAINT ... NOT VALID  → instant, doesn't scan existing rows
  #   - VALIDATE CONSTRAINT           → scans rows but only takes a SHARE lock
  #                                     (reads still work, only writes blocked briefly)
  #
  # For smaller tables, change_column_null is fine:

  def up
    # Safe for smaller tables
    change_column_null :issues, :author_name, false

    # For very large tables (millions of rows), use this instead:
    # execute <<~SQL
    #   ALTER TABLE issues
    #   ADD CONSTRAINT issues_author_name_not_null
    #   CHECK (author_name IS NOT NULL) NOT VALID;
    # SQL
    # execute "ALTER TABLE issues VALIDATE CONSTRAINT issues_author_name_not_null;"
  end

  def down
    change_column_null :issues, :author_name, true
  end
end
