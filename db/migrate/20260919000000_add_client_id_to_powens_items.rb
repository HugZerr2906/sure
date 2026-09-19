class AddClientIdToPowensItems < ActiveRecord::Migration[7.2]
  def change
    add_column :powens_items, :client_id, :string
  end
end
