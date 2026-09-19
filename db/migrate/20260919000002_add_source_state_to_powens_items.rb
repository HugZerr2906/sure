class AddSourceStateToPowensItems < ActiveRecord::Migration[7.2]
  def change
    add_column :powens_items, :connection_state_source, :string
    add_column :powens_items, :access_expires_at, :date
  end
end
