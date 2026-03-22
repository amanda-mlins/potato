class AddNotNullConstraints < ActiveRecord::Migration[8.1]
  def change
    change_column_null :projects, :name, false
    change_column_null :issues, :title, false
    change_column_null :issues, :status, false, 0
    change_column_null :labels, :name, false
    change_column_null :labels, :color, false
  end
end
