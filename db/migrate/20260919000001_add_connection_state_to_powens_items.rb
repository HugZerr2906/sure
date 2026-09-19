class AddConnectionStateToPowensItems < ActiveRecord::Migration[7.2]
  def change
    add_column :powens_items, :connection_state, :string
  end
end
