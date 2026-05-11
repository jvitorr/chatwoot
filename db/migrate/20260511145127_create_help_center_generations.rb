class CreateHelpCenterGenerations < ActiveRecord::Migration[7.1]
  def change
    create_table :help_center_generations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :portal, null: false, foreign_key: true
      t.integer :status,            null: false, default: 0
      t.jsonb :plan
      t.integer :articles_finished, null: false, default: 0
      t.text :skip_reason
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
  end
end
