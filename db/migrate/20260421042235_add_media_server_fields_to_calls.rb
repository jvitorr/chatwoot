class AddMediaServerFieldsToCalls < ActiveRecord::Migration[7.0]
  def change
    add_column :calls, :media_session_id, :string
    add_index :calls, :media_session_id, unique: true
    add_index :calls, [:accepted_by_agent_id, :status]
  end
end
