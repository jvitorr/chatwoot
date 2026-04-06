class ChangeAuthConfigToTextInCaptainCustomTools < ActiveRecord::Migration[7.1]
  def up
    change_column :captain_custom_tools, :auth_config, :text, default: nil
  end

  def down
    execute <<~SQL.squish
      ALTER TABLE captain_custom_tools
      ALTER COLUMN auth_config TYPE jsonb USING auth_config::jsonb,
      ALTER COLUMN auth_config SET DEFAULT '{}'::jsonb
    SQL
  end
end
