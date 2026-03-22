class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues do |t|
      t.string :title
      t.text :description
      t.integer :status
      t.references :project, null: false, foreign_key: true

      t.timestamps
    end
  end
end
